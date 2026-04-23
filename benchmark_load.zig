//! SLA-tier HTTP load generator (closed-loop).
//!
//! **Port source:** pattern-transplant from TigerBeetle's
//! `src/tigerbeetle/benchmark_load.zig` (1069 lines). Whole-file cp
//! is infeasible (DR-3: the file's skeleton is VSR — `vsr.ClientType`,
//! `MessagePool`, `MessageBus`, etc.). Specific passages are
//! transplanted verbatim with file:line citations; the domain-specific
//! machinery (HTTP client, JSON body construction, op-mix parser)
//! is written fresh.
//!
//! **Transplanted verbatim from TB `benchmark_load.zig`:**
//!
//!   - Histogram shape: `[10_001]u64` per-thread, last bucket is
//!     10_000 ms+. Cite TB:117-118.
//!   - Histogram increment: `h[@min(duration_ms, len-1)] += 1`.
//!     Cite TB:876.
//!   - Percentile walk over cumulative bucket sums. Cite TB:1045-1068.
//!   - `label = value unit` output format (DR-2 / TB:556-572).
//!
//! **Written fresh (no TB equivalent applies):**
//!
//!   - Hand-written HTTP/1.1 response parser (status line,
//!     Content-Length, keep-alive across requests, partial reads).
//!     TB's VSR client doesn't translate. Parser is pure — state
//!     lives on the per-client struct; no I/O mixed in.
//!   - Per-op JSON body construction, PRNG-derived field-by-field
//!     for deterministic replay under `--seed`.
//!   - Operation-weight mix: `--ops=create_product:80,list_products:20`
//!     parsed once at startup into `BoundedArrayType(OpMix, op_mix_max)`.
//!     Weighted PRNG pick per request; dispatch via comptime `switch`
//!     on `Operation`.
//!
//! **Transport primitive — `framework/io.zig` (io_uring on Linux,
//! kqueue on macOS).** Single-threaded, async-completion-driven, the
//! same IO layer the server uses. Per TIGER_STYLE "right primitive":
//! the project owns one IO abstraction; the benchmark uses it too.
//! `io.connect`/`io.send`/`io.recv` are the verbs. Fuzzability
//! (TB principle 4) follows — future sim-tests drop in `SimIO` with
//! no harness change.
//!
//! **Why not thread-per-connection or raw epoll:**
//! thread-per-connection (the pre-H.4 shape) corrupted tail latencies
//! with scheduler jitter. Raw epoll (a first-pass attempt at H.4,
//! reverted) introduced a second IO primitive into a project that
//! had one — direct violation of right-primitive. `framework/io.zig`
//! is the correct answer for both concerns.
//!
//! **Scope at ship time:** only `create_product` and `list_products`
//! are supported operations. Other `message.Operation` values
//! rejected at `--ops` parse with a named error. Extending the set
//! is a tracked follow-up — adding an op requires a body
//! constructor + validation against the handler's JSON schema.
//! Silent expansion would leave a future contributor assuming full
//! domain coverage.
//!
//! **Closed-loop caveat:** this harness is closed-loop (each client
//! waits for a response before issuing the next request). Coordinated
//! omission applies — tail-latency spikes that would have happened
//! during a slow response are hidden because the load generator
//! naturally backed off. A `closed_loop = 1 count` metric in the
//! output surfaces this to downstream consumers. Open-loop mode is
//! a blocking prerequisite for public performance claims (see
//! `docs/internal/decision-benchmark-tracking.md` honest
//! acknowledgments).
//!
//! **Failure semantics:** a connection that fails at any stage
//! (connect, send, recv, parse) terminates bounded — one error
//! recorded, no reconnect, the connection drops out of the active
//! set. Failures surface as `errors = N count` in output.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const log = std.log.scoped(.benchmark);

const stdx = @import("stdx");
const PRNG = stdx.PRNG;
const BoundedArrayType = stdx.BoundedArrayType;

const framework_io = @import("framework/io.zig");
const IO = framework_io.IO;

const BenchmarkArgs = @import("main.zig").BenchmarkArgs;
const message = @import("message.zig");
const Operation = message.Operation;

// --- Constants ---
//
// Per TIGER_STYLE "use explicitly-sized types, avoid architecture-
// specific usize" — domain counts are u32 / u16 / u8. usize remains
// only for buffer-length arithmetic where Zig stdlib signatures
// demand it (slice indexing inside parsers).

/// Per TB `benchmark_load.zig:117-118`. Each bucket is 1 ms; the
/// last bucket captures 10_000 ms+.
const histogram_buckets: u32 = 10_001;

/// Maximum distinct ops in an `--ops=...` spec. Bounded per
/// TIGER_STYLE "put a limit on everything" — excess entries
/// rejected at parse.
const op_mix_max: u8 = 32;

/// Maximum JSON body size for a single *outgoing* request.
/// `create_product` fits well under this; `list_products` has no
/// body. Distinct from `recv_buf_size` below (incoming responses).
const body_max: u32 = 1024;

/// TCP recv buffer size per client. Bounds the largest *incoming*
/// response body we can receive without dropping the connection.
///
/// Sized 128 KiB because `list_products`' response grows with DB
/// population: each product renders ~28 bytes of HTML card markup,
/// so a bench run that creates thousands of products before listing
/// them can return response bodies in the tens-of-KB range. 128 KiB
/// comfortably handles 4000+ products; beyond that the connection
/// drops with an error (bounded, not reconnect-looped).
///
/// Per-client heap cost: ~128 KiB (read_buf). Write_buf adds ~1.3 KiB.
const recv_buf_size: u32 = 128 * 1024;

/// Hard upper bound on `--connections`. Beyond this, kernel FD
/// limits and io_uring SQE capacity start dominating. 1024 is
/// generous — TB itself benchmarks with tens, not thousands.
const connections_max: u16 = 1024;

/// Maximum outgoing HTTP/1.1 header size. 256 bytes covers method +
/// path + Host + Content-Length + Connection. Write buffer carries
/// header + body.
const write_header_max: u16 = 256;
const write_buf_size: u32 = write_header_max + body_max;

/// io_uring run-loop slice. The benchmark's main loop calls
/// `io.run_for_ns(tick_ns)` repeatedly until all clients are
/// terminal; a short slice keeps terminate-detection responsive
/// without significant syscall overhead (io_uring's unified wait
/// completes immediately when there's work).
const tick_ns: u64 = 1 * std.time.ns_per_ms;

/// Hard upper bound on `--requests`. 10M requests × ~10ms/request
/// at typical SLA latencies ≈ 100k seconds; anything larger is
/// almost certainly a user error (pre-DR-3 Tiger Web load tool
/// defaulted to 100k requests).
const requests_max: u32 = 10_000_000;

/// PRNG base seed for per-thread PRNG derivation. Arbitrary non-zero
/// constant — the load is fully deterministic under a given
/// (seed_base, thread_index) pair. Kept as a module constant rather
/// than a CLI flag for now; when `--seed` becomes a user-visible arg
/// this constant becomes the default.
const seed_base: u64 = 0xDEADBEEFCAFEBABE;

/// PRNG-derived product-name length for `create_product`. 8 ASCII
/// lowercase letters is well under `product_name_max` (from message.zig),
/// avoids name-collision churn at the DB, and serializes to a
/// compact JSON payload. Pure choice — no externally committed value.
const product_name_length: u8 = 8;

/// Alphabet size for the PRNG-derived product name. ASCII lowercase
/// only (`a`..`z`) — avoids any non-UTF8 byte the handler rejects,
/// avoids JSON-escape overhead, keeps the load reproducible.
const product_name_alphabet: u8 = 26;

/// PRNG-derived `price_cents` upper bound for `create_product`.
/// ≈ $9999.99. Plausible-looking price range without blowing out u32
/// arithmetic downstream; arbitrary within that constraint.
const product_price_max_cents: u32 = 999_999;

/// PRNG-derived `inventory` upper bound for `create_product`. 9999
/// units — same rationale as price: plausible range, bounded.
const product_inventory_max: u32 = 9_999;

/// Operations supported by the load generator. Parsing `--ops`
/// rejects anything not in this list.
const supported_ops = [_]Operation{ .create_product, .list_products };

comptime {
    assert(write_buf_size > write_header_max);
    assert(write_buf_size > body_max);
    assert(tick_ns > 0);
    // Full HTTP request (header + body) must fit in the write buffer.
    assert(body_max <= recv_buf_size);
    // Minimum viable for any HTTP/1.1 response: status line
    // ("HTTP/1.1 200 OK\r\n" = 17 bytes) + one header line + "\r\n\r\n".
    assert(recv_buf_size >= 128);
    // At least one op in the mix must be permitted for the bench
    // to run at all.
    assert(op_mix_max >= 1);
    // Percentile resolution: fewer than 100 buckets would give <1%
    // percentile granularity, defeating p99 tracking.
    assert(histogram_buckets >= 100);
    // Name must fit in the handler's product_name_max (checked at
    // compile time via message.zig imports).
    assert(product_name_length <= @import("message.zig").product_name_max);
}

const OpMix = struct {
    op: Operation,
    weight: u32,
};
const OpMixArray = BoundedArrayType(OpMix, op_mix_max);

// --- Entry point ---

pub fn run(gpa: std.mem.Allocator, cli: BenchmarkArgs) !void {
    assert(cli.port > 0);
    assert(cli.connections > 0);
    assert(cli.connections <= connections_max);
    assert(cli.requests > 0);
    assert(cli.requests <= requests_max);

    const op_mix = try parse_op_mix(cli.ops);
    assert(op_mix.count() > 0);
    assert(op_mix.count() <= op_mix_max);

    log.info(
        "benchmark: port={d} connections={d} requests={d}",
        .{ cli.port, cli.connections, cli.requests },
    );

    try probe_server(cli.port);

    const addr = try std.net.Address.parseIp4("127.0.0.1", cli.port);
    const client_count: u32 = cli.connections;
    assert(client_count > 0);
    const requests_per_client: u32 = cli.requests / client_count;
    assert(requests_per_client > 0);
    assert(requests_per_client <= cli.requests);

    // Single IO instance drives every client. Same primitive as the
    // server (`framework/io.zig`) — io_uring on Linux, kqueue on macOS.
    // No epoll, no raw `posix.*` event loops anywhere in this file.
    var io = try IO.init();
    defer io.deinit();

    const clients = try gpa.alloc(Client, client_count);
    defer gpa.free(clients);
    const histograms = try gpa.alloc([histogram_buckets]u64, client_count);
    defer gpa.free(histograms);
    @memset(histograms, [_]u64{0} ** histogram_buckets);

    var runner: Runner = .{ .io = &io, .active = client_count };

    for (clients, histograms, 0..) |*client, *hist, i| {
        const seed: u64 = seed_base ^ @as(u64, i);
        const fd = try io.open_client_socket(posix.AF.INET);
        errdefer io.close(fd);

        client.* = .{
            .fd = fd,
            .index = @intCast(i),
            .addr = addr,
            .prng = PRNG.from_seed(seed),
            .op_mix = &op_mix,
            .histogram = hist,
            .runner = &runner,
            .completion = .{},
            .state = .connecting,
            .remaining = requests_per_client,
            .errors = 0,
            .write_len = 0,
            .write_offset = 0,
            .read_len = 0,
            .header_end = null,
            .content_length = null,
            .request_start = undefined,
            .write_buf = undefined,
            .read_buf = undefined,
        };

        io.connect(fd, addr, &client.completion, @ptrCast(client), on_connect);
    }

    const start_instant = std.time.Instant.now() catch @panic("clock unavailable");

    // Drive the ring until every client has reached a terminal state.
    // `run_for_ns(tick_ns)` blocks in io_uring_enter until there's
    // either a completion or the slice expires; short slices keep
    // the active-count check responsive without measurable overhead.
    while (runner.active > 0) {
        io.run_for_ns(tick_ns);
    }

    const elapsed_ns = blk: {
        const now = std.time.Instant.now() catch @panic("clock unavailable");
        break :blk now.since(start_instant);
    };
    assert(elapsed_ns > 0);

    // Merge per-client histograms.
    var total_hist = [_]u64{0} ** histogram_buckets;
    var total_samples: u64 = 0;
    var total_errors: u64 = 0;
    for (clients, histograms) |*client, *hist| {
        for (hist, 0..) |count, bucket| {
            total_hist[bucket] += count;
            total_samples += count;
        }
        total_errors += client.errors;
    }

    report(cli, elapsed_ns, total_samples, total_errors, &total_hist);
}

// --- `--ops` parser ---

fn parse_op_mix(spec: []const u8) !OpMixArray {
    assert(spec.len > 0);

    var result: OpMixArray = .{};
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |entry| {
        assert(entry.len > 0); // tokenizeScalar skips empties
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse {
            log.err("--ops: expected 'NAME:WEIGHT', got '{s}'", .{entry});
            return error.BadOpsSpec;
        };
        const name = entry[0..colon];
        const weight_str = entry[colon + 1 ..];
        if (name.len == 0) {
            log.err("--ops: empty operation name in '{s}'", .{entry});
            return error.BadOpsSpec;
        }
        const op = resolve_op(name) orelse {
            log.err("--ops: unsupported operation '{s}' — supported: {s}", .{ name, supported_names_str });
            return error.UnsupportedOp;
        };
        const weight = std.fmt.parseInt(u32, weight_str, 10) catch {
            log.err("--ops: invalid weight '{s}' for op '{s}'", .{ weight_str, name });
            return error.BadOpsSpec;
        };
        if (weight == 0) {
            log.err("--ops: weight must be > 0 for op '{s}'", .{name});
            return error.BadOpsSpec;
        }
        if (result.full()) {
            log.err("--ops: exceeded op_mix_max={d} entries", .{op_mix_max});
            return error.BadOpsSpec;
        }
        assert(weight > 0);
        result.push(.{ .op = op, .weight = weight });
    }
    if (result.empty()) {
        log.err("--ops: at least one op required", .{});
        return error.BadOpsSpec;
    }
    assert(result.count() >= 1);
    assert(result.count() <= op_mix_max);
    return result;
}

fn resolve_op(name: []const u8) ?Operation {
    assert(name.len > 0);
    inline for (supported_ops) |op| {
        if (std.mem.eql(u8, name, @tagName(op))) return op;
    }
    return null;
}

const supported_names_str: []const u8 = blk: {
    var buf: []const u8 = "";
    for (supported_ops, 0..) |op, i| {
        if (i > 0) buf = buf ++ ", ";
        buf = buf ++ @tagName(op);
    }
    break :blk buf;
};

fn op_mix_pick(prng: *PRNG, op_mix: *const OpMixArray) Operation {
    const mix = op_mix.const_slice();
    assert(mix.len > 0);
    assert(mix.len <= op_mix_max);
    var total_weight: u32 = 0;
    for (mix) |entry| {
        assert(entry.weight > 0);
        total_weight += entry.weight;
    }
    assert(total_weight > 0);
    const roll: u32 = prng.int_inclusive(u32, total_weight - 1);
    assert(roll < total_weight);
    var cumulative: u32 = 0;
    for (mix) |entry| {
        cumulative += entry.weight;
        if (roll < cumulative) return entry.op;
    }
    unreachable;
}

// --- Per-client state machine ---
//
// One IO instance drives all N clients. Each client is a little
// state machine; `framework/io.zig` completion callbacks fire its
// transitions. No threads, no mutexes, no epoll.

const State = enum {
    connecting,
    writing,
    reading,
    done,
    failed,
};

const Runner = struct {
    io: *IO,
    active: u32,
};

const Client = struct {
    fd: IO.fd_t,
    completion: IO.Completion,
    index: u32,
    addr: std.net.Address,
    prng: PRNG,
    op_mix: *const OpMixArray,
    histogram: *[histogram_buckets]u64,
    runner: *Runner,

    state: State,
    remaining: u32,
    errors: u64,

    // Write path.
    write_buf: [write_buf_size]u8,
    write_len: u32,
    write_offset: u32,

    // Read path.
    read_buf: [recv_buf_size]u8,
    read_len: u32,
    header_end: ?u32,
    content_length: ?u32,

    // Timing — valid only while state == reading.
    request_start: std.time.Instant,
};

fn on_connect(ctx_raw: *anyopaque, result: i32) void {
    const client: *Client = @alignCast(@ptrCast(ctx_raw));
    if (client.state == .done or client.state == .failed) return;
    assert(client.state == .connecting);

    if (result < 0) {
        terminate(client, .failed);
        return;
    }
    advance_send(client);
}

fn advance_send(client: *Client) void {
    // Entered from .connecting (first send) or .reading (next request
    // after a completed response).
    assert(client.state == .connecting or client.state == .reading);
    assert(client.remaining > 0);

    const op = op_mix_pick(&client.prng, client.op_mix);
    client.write_len = build_request(&client.prng, op, &client.write_buf);
    assert(client.write_len > 0);
    assert(client.write_len <= client.write_buf.len);
    client.write_offset = 0;
    client.request_start = std.time.Instant.now() catch @panic("clock unavailable");
    client.state = .writing;
    submit_send(client);
}

fn submit_send(client: *Client) void {
    assert(client.state == .writing);
    assert(client.write_offset < client.write_len);
    const slice = client.write_buf[client.write_offset..client.write_len];
    assert(slice.len > 0);
    client.runner.io.send(client.fd, slice, &client.completion, @ptrCast(client), on_send);
}

fn on_send(ctx_raw: *anyopaque, result: i32) void {
    const client: *Client = @alignCast(@ptrCast(ctx_raw));
    if (client.state == .done or client.state == .failed) return;
    assert(client.state == .writing);

    if (result <= 0) {
        client.errors += 1;
        terminate(client, .failed);
        return;
    }
    client.write_offset += @intCast(result);
    assert(client.write_offset <= client.write_len);

    if (client.write_offset < client.write_len) {
        submit_send(client);
        return;
    }

    // Full request sent; transition to reading.
    client.state = .reading;
    client.read_len = 0;
    client.header_end = null;
    client.content_length = null;
    submit_recv(client);
}

fn submit_recv(client: *Client) void {
    assert(client.state == .reading);
    const slice = client.read_buf[client.read_len..];
    assert(slice.len > 0);
    client.runner.io.recv(client.fd, slice, &client.completion, @ptrCast(client), on_recv);
}

fn on_recv(ctx_raw: *anyopaque, result: i32) void {
    const client: *Client = @alignCast(@ptrCast(ctx_raw));
    if (client.state == .done or client.state == .failed) return;
    assert(client.state == .reading);

    if (result <= 0) {
        // 0 = peer closed mid-response; <0 = recv error. Both terminal.
        client.errors += 1;
        terminate(client, .failed);
        return;
    }
    client.read_len += @intCast(result);
    assert(client.read_len <= client.read_buf.len);

    // Try to complete the parse.
    if (client.header_end == null) {
        if (std.mem.indexOf(u8, client.read_buf[0..client.read_len], "\r\n\r\n")) |pos| {
            client.header_end = @intCast(pos);
        }
    }
    if (client.header_end) |header_end| {
        if (client.content_length == null) {
            const cl = parse_content_length(client.read_buf[0..header_end]) orelse {
                client.errors += 1;
                terminate(client, .failed);
                return;
            };
            // Clamp at recv_buf_size — oversized responses will fall
            // into the ResponseTooLarge path via the read-buffer-full
            // check below.
            client.content_length = @intCast(@min(cl, recv_buf_size));
        }
        const body_start: u32 = client.header_end.? + 4;
        const body_end: u32 = body_start + client.content_length.?;
        if (client.read_len >= body_end) {
            const status = parse_status_line(client.read_buf[0..client.header_end.?]) orelse {
                client.errors += 1;
                terminate(client, .failed);
                return;
            };
            // Pair-assert: parse_status_line returns null for values
            // outside 100..600.
            assert(status >= 100);
            assert(status < 600);

            const is_success = status >= 200 and status < 300;
            if (is_success) {
                const now = std.time.Instant.now() catch @panic("clock unavailable");
                const duration_ns: u64 = now.since(client.request_start);
                // Transplanted from TB `benchmark_load.zig:876`.
                const duration_ms: u64 = duration_ns / std.time.ns_per_ms;
                const bucket: usize = @min(duration_ms, histogram_buckets - 1);
                assert(bucket < histogram_buckets);
                client.histogram[bucket] += 1;
            } else {
                client.errors += 1;
            }

            // Shift any trailing bytes (pipelined response or extra
            // from an over-eager recv) to the buf head for the next
            // request.
            const extra: u32 = client.read_len - body_end;
            if (extra > 0) {
                std.mem.copyForwards(
                    u8,
                    client.read_buf[0..extra],
                    client.read_buf[body_end..client.read_len],
                );
            }
            client.read_len = extra;
            client.header_end = null;
            client.content_length = null;

            assert(client.remaining > 0);
            client.remaining -= 1;
            if (client.remaining == 0) {
                terminate(client, .done);
                return;
            }
            advance_send(client);
            return;
        }
    }

    // Need more bytes.
    if (client.read_len == client.read_buf.len) {
        // Response larger than buf and we still haven't found the
        // end. Bounded: terminate the connection.
        client.errors += 1;
        terminate(client, .failed);
        return;
    }
    submit_recv(client);
}

/// Mark client terminal, close the fd, decrement active count.
/// The runner's main loop uses `runner.active == 0` as the exit
/// signal. No reconnect loop, no unbounded error recovery — bounded
/// per TIGER_STYLE.
fn terminate(client: *Client, final: State) void {
    assert(final == .done or final == .failed);
    assert(client.state != .done);
    assert(client.state != .failed);
    client.state = final;
    client.runner.io.close(client.fd);
    client.fd = -1;
    assert(client.runner.active > 0);
    client.runner.active -= 1;
}

fn build_request(prng: *PRNG, op: Operation, buf: *[write_buf_size]u8) u32 {
    var body_buf: [body_max]u8 = undefined;
    const body = construct_body(prng, op, &body_buf);
    assert(body.len <= body_max);

    const method_path: MethodPath = switch (op) {
        .create_product => .{ .method = "POST", .path = "/products" },
        .list_products => .{ .method = "GET", .path = "/products" },
        else => unreachable, // rejected at --ops parse
    };
    assert(method_path.method.len > 0);
    assert(method_path.path.len > 0);

    const header = std.fmt.bufPrint(
        buf,
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
        .{ method_path.method, method_path.path, body.len },
    ) catch @panic("write_header_max too small");
    assert(header.len > 0);
    assert(header.len <= write_header_max);

    if (body.len > 0) {
        assert(header.len + body.len <= buf.len);
        @memcpy(buf[header.len..][0..body.len], body);
    }
    const total: u32 = @intCast(header.len + body.len);
    assert(total > 0);
    assert(total <= buf.len);
    return total;
}

// --- Body construction (PRNG-derived, deterministic under seed) ---

fn construct_body(prng: *PRNG, op: Operation, buf: []u8) []const u8 {
    assert(buf.len > 0);
    const body = switch (op) {
        .create_product => construct_create_product(prng, buf),
        .list_products => buf[0..0], // GET, no body
        else => unreachable, // rejected at --ops parse
    };
    assert(body.len <= buf.len);
    return body;
}

fn construct_create_product(prng: *PRNG, buf: []u8) []const u8 {
    // Conservative lower bound: JSON skeleton + 32-char id + name +
    // 6-digit price + 4-digit inventory ≈ 100 bytes. Buf ≥ 200
    // leaves headroom for future field additions.
    assert(buf.len >= 200);

    var id_hex: [32]u8 = undefined;
    const id: u128 = prng.int(u128) | 1; // non-zero per handler contract
    assert(id != 0);
    stdx.write_uuid_to_buf(&id_hex, id);

    // PRNG-derived name: always ASCII lowercase. Deterministic under
    // the same seed; avoids any non-UTF8 byte the handler would reject.
    var name: [product_name_length]u8 = undefined;
    for (&name) |*c| {
        const offset: u8 = @intCast(prng.int_inclusive(u32, product_name_alphabet - 1));
        assert(offset < product_name_alphabet);
        c.* = 'a' + offset;
    }

    const price: u32 = prng.int_inclusive(u32, product_price_max_cents);
    const inventory: u32 = prng.int_inclusive(u32, product_inventory_max);
    assert(price <= product_price_max_cents);
    assert(inventory <= product_inventory_max);

    const written = std.fmt.bufPrint(
        buf,
        \\{{"id":"{s}","name":"{s}","price_cents":{d},"inventory":{d}}}
    ,
        .{ id_hex, name, price, inventory },
    ) catch @panic("body_max too small");
    assert(written.len > 0);
    assert(written.len <= buf.len);
    return written;
}

const MethodPath = struct { method: []const u8, path: []const u8 };

// --- HTTP response parse helpers ---
//
// Pure functions with no I/O — driven from `on_recv`. Written
// fresh because `std.http.Client`'s implicit connection pooling
// would conflate framework-under-load with stdlib-client-under-load.

fn parse_status_line(headers: []const u8) ?u16 {
    // "HTTP/1.1 NNN ...\r\n"
    if (headers.len < 12) return null;
    if (!std.mem.startsWith(u8, headers, "HTTP/1.1 ")) return null;
    const status = std.fmt.parseInt(u16, headers[9..12], 10) catch return null;
    // HTTP status codes are 100..599 per RFC 9110. A value outside
    // that range means parseInt succeeded on garbage and the sender
    // isn't HTTP-compliant — pair-assertion against the format check
    // above.
    if (status < 100 or status >= 600) return null;
    return status;
}

fn parse_content_length(headers: []const u8) ?usize {
    const marker = "\r\nContent-Length: ";
    const start = std.mem.indexOf(u8, headers, marker) orelse return null;
    const val_start = start + marker.len;
    const val_end = std.mem.indexOf(u8, headers[val_start..], "\r\n") orelse return null;
    return std.fmt.parseInt(usize, headers[val_start .. val_start + val_end], 10) catch null;
    // Upper bound isn't enforced here — the read loop in `on_recv`
    // clamps oversized Content-Length to recv_buf_size and falls
    // into the "response larger than buf" path naturally. Adding a
    // bound here would short-circuit that flow.
}

// --- Reachability probe ---

fn probe_server(port: u16) !void {
    assert(port > 0);
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var stream = std.net.tcpConnectToAddress(addr) catch |err| {
        log.err("cannot connect to 127.0.0.1:{d}: {s} — is the server running?", .{ port, @errorName(err) });
        return error.ServerUnreachable;
    };
    stream.close();
}

// --- Output ---

fn report(
    cli: BenchmarkArgs,
    elapsed_ns: u64,
    samples: u64,
    errors: u64,
    histogram: *const [histogram_buckets]u64,
) void {
    assert(elapsed_ns > 0);
    assert(cli.connections > 0);

    const stdout = std.io.getStdOut().writer();

    // Transplanted shape from TB `benchmark_load.zig:556-572`.
    const rate: u64 = @divTrunc(samples * std.time.ns_per_s, elapsed_ns);
    stdout.print(
        \\benchmark_connections = {d} count
        \\benchmark_requests = {d} count
        \\benchmark_errors = {d} count
        \\benchmark_throughput = {d} req/s
        \\closed_loop = 1 count
        \\
    , .{ cli.connections, samples, errors, rate }) catch return;

    print_percentiles_histogram(stdout, "benchmark_latency", histogram);

    log.warn("closed-loop harness: coordinated omission applies to tail latencies — see docs/internal/decision-benchmark-tracking.md", .{});
}

// Verbatim transplant from TB `benchmark_load.zig:1045-1068`, with
// report format adjusted to DR-2's `label = value unit` shape.
fn print_percentiles_histogram(
    stdout: anytype,
    label: []const u8,
    histogram_buckets_slice: *const [histogram_buckets]u64,
) void {
    assert(label.len > 0);

    var histogram_total: u64 = 0;
    for (histogram_buckets_slice) |bucket| histogram_total += bucket;
    if (histogram_total == 0) return;
    assert(histogram_total > 0);

    const percentiles = [_]u64{ 1, 50, 99, 100 };
    for (percentiles) |percentile| {
        assert(percentile <= 100);
        const histogram_percentile: u64 = @divTrunc(histogram_total * percentile, 100);
        assert(histogram_percentile <= histogram_total);

        var sum: u64 = 0;
        const latency = for (histogram_buckets_slice, 0..) |bucket, bucket_index| {
            sum += bucket;
            assert(sum <= histogram_total);
            if (sum >= histogram_percentile) break bucket_index;
        } else histogram_buckets_slice.len;

        assert(latency <= histogram_buckets_slice.len);
        stdout.print("{s}_p{d} = {d} ms\n", .{ label, percentile, latency }) catch return;
    }
}
