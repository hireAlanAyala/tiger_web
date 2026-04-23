//! SLA-tier HTTP load generator (closed-loop).
//!
//! **Port source:** pattern-transplant from TigerBeetle's
//! `src/tigerbeetle/benchmark_load.zig` (1069 lines). Whole-file cp
//! is infeasible (DR-3: the file's skeleton is VSR — `vsr.ClientType`,
//! `MessagePool`, `MessageBus`, etc.). Specific passages are
//! transplanted verbatim with file:line citations; the domain-specific
//! machinery (HTTP client, JSON body construction, op-mix parser,
//! warmup) is written fresh.
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
//!   - Raw TCP via `std.net.Stream` with a hand-written HTTP/1.1
//!     response parser (status line, Content-Length, keep-alive,
//!     partial reads). TB's VSR client doesn't translate. Raw-TCP
//!     matches TB's style for their manual-ping in `benchmark_driver`.
//!   - Per-op JSON body construction, PRNG-derived field-by-field for
//!     deterministic replay under `--seed`.
//!   - Operation-weight mix: `--ops=create_product:80,list_products:20`
//!     parsed once at startup into `BoundedArrayType(OpMix, op_mix_max)`.
//!     Weighted PRNG pick per request; dispatch via comptime `switch`
//!     on `Operation`.
//!   - Thread-per-connection (std.Thread). HTTP sockets are blocking;
//!     a single-threaded event loop would require epoll/io_uring
//!     plumbing that duplicates the server.
//!
//! **Scope at ship time:** only `create_product` and `list_products`
//! are supported operations. Other `message.Operation` values
//! rejected at `--ops` parse with a named error. Extending the set
//! is a tracked follow-up — adding an op requires a body
//! constructor + validation against the handler's JSON schema.
//! Silent expansion would leave a future contributor assuming full
//! domain coverage.
//!
//! **Closed-loop caveat:** this harness is closed-loop (each thread
//! waits for a response before issuing the next request). Coordinated
//! omission applies — tail-latency spikes that would have happened
//! during a slow response are hidden because the load generator
//! naturally backed off. A `closed_loop = 1 count` metric in the
//! output surfaces this to downstream consumers. Open-loop mode is
//! a blocking prerequisite for public performance claims (see
//! `docs/internal/decision-benchmark-tracking.md` honest
//! acknowledgments).
//!
//! **Failure semantics:** when a request fails (non-2xx, socket
//! closed mid-response, parse error), the thread records an error,
//! reconnects once, and continues. Failures are load-bearing signal
//! — surfaced as `errors = N count` in output. Bounded: one
//! reconnect per failure; if the reconnect also fails, the thread
//! exits early.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.benchmark);

const stdx = @import("stdx");
const PRNG = stdx.PRNG;
const BoundedArrayType = stdx.BoundedArrayType;

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

/// TCP recv buffer size per connection. Bounds the largest
/// *incoming* response body we can receive without ResponseTooLarge.
///
/// Sized 128 KiB because `list_products`' response grows with DB
/// population: each product renders ~28 bytes of HTML card markup,
/// so a bench run that creates thousands of products before listing
/// them can return response bodies in the tens-of-KB range. 128 KiB
/// comfortably handles 4000+ products; beyond that, ResponseTooLarge
/// fires and the thread records an error + reconnects.
///
/// Per-thread stack cost: ~256 KiB (recv_buf + leftover). Default
/// thread stack is 8 MiB, leaving ample headroom.
const recv_buf_size: u32 = 128 * 1024;

/// Hard upper bound on `--connections`. Beyond this, thread-spawn
/// pressure and kernel FD limits make the measurement dominate by
/// OS effects rather than framework behavior. 1024 is generous — TB
/// itself benchmarks with tens, not thousands.
const connections_max: u16 = 1024;

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
    // The response parser copies the leftover buffer into `buf`
    // before reading — body + headers must fit.
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

    // Quick server reachability probe — connect, send a simple GET,
    // disconnect. Confirms the server is up before we spawn threads.
    try probe_server(cli.port);

    const addr = try std.net.Address.parseIp4("127.0.0.1", cli.port);
    const thread_count: u32 = cli.connections;
    assert(thread_count > 0);
    const requests_per_thread: u32 = cli.requests / thread_count;
    assert(requests_per_thread > 0);
    assert(requests_per_thread <= cli.requests);

    const threads = try gpa.alloc(std.Thread, thread_count);
    defer gpa.free(threads);

    const contexts = try gpa.alloc(ClientContext, thread_count);
    defer gpa.free(contexts);

    const histograms = try gpa.alloc([histogram_buckets]u64, thread_count);
    defer gpa.free(histograms);
    @memset(histograms, [_]u64{0} ** histogram_buckets);

    const start_instant = std.time.Instant.now() catch @panic("clock unavailable");

    for (threads, contexts, histograms, 0..) |*t, *ctx, *hist, i| {
        ctx.* = ClientContext{
            .index = @intCast(i),
            .addr = addr,
            .op_mix = &op_mix,
            .requests = requests_per_thread,
            .histogram = hist,
            .errors = 0,
        };
        t.* = try std.Thread.spawn(.{}, client_loop, .{ctx});
    }

    for (threads) |t| t.join();

    const elapsed_ns = blk: {
        const now = std.time.Instant.now() catch @panic("clock unavailable");
        break :blk now.since(start_instant);
    };
    assert(elapsed_ns > 0);

    // Merge per-thread histograms.
    var total_hist = [_]u64{0} ** histogram_buckets;
    var total_samples: u64 = 0;
    var total_errors: u64 = 0;
    for (contexts, histograms) |*ctx, *hist| {
        for (hist, 0..) |count, bucket| {
            total_hist[bucket] += count;
            total_samples += count;
        }
        total_errors += ctx.errors;
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

// --- Per-thread client ---

const ClientContext = struct {
    index: u32,
    addr: std.net.Address,
    op_mix: *const OpMixArray,
    requests: u32,
    histogram: *[histogram_buckets]u64,
    // Written only by this thread; read by main after join. No sync.
    errors: u64,
};

fn client_loop(ctx: *ClientContext) void {
    assert(ctx.requests > 0);

    // Per-thread PRNG derived from the canonical bench seed + index,
    // so replay under the same seed is deterministic even with many
    // threads. Explicit XOR keeps each thread's PRNG independent.
    const seed: u64 = seed_base ^ @as(u64, ctx.index);
    var prng = PRNG.from_seed(seed);

    var stream = std.net.tcpConnectToAddress(ctx.addr) catch |err| {
        log.err("client {d}: connect failed: {s}", .{ ctx.index, @errorName(err) });
        ctx.errors += 1;
        return;
    };
    defer stream.close();

    var body_buf: [body_max]u8 = undefined;
    var recv_buf: [recv_buf_size]u8 = undefined;
    var recv_state: ResponseParser = .{};

    for (0..ctx.requests) |_| {
        const op = op_mix_pick(&prng, ctx.op_mix);
        const body = construct_body(&prng, op, &body_buf);
        assert(body.len <= body_max);

        const req_start = std.time.Instant.now() catch @panic("clock unavailable");
        send_request(&stream, op, body) catch |err| {
            log.warn("client {d}: send failed: {s}; reconnecting", .{ ctx.index, @errorName(err) });
            ctx.errors += 1;
            reconnect(ctx, &stream, &recv_state) catch return;
            continue;
        };
        const status = recv_response(&stream, &recv_buf, &recv_state) catch |err| {
            log.warn("client {d}: recv failed: {s}; reconnecting", .{ ctx.index, @errorName(err) });
            ctx.errors += 1;
            reconnect(ctx, &stream, &recv_state) catch return;
            continue;
        };
        // Pair-assert the status is in the HTTP-valid range. A value
        // outside 100..600 means parse_status_line returned garbage.
        assert(status >= 100);
        assert(status < 600);
        if (status < 200 or status >= 300) {
            ctx.errors += 1;
            continue;
        }

        const now = std.time.Instant.now() catch @panic("clock unavailable");
        const duration_ns: u64 = now.since(req_start);
        // Transplanted from TB `benchmark_load.zig:876`.
        const duration_ms: u64 = duration_ns / std.time.ns_per_ms;
        const bucket: usize = @min(duration_ms, histogram_buckets - 1);
        assert(bucket < histogram_buckets);
        ctx.histogram[bucket] += 1;
    }
}

/// Close the current stream, reconnect, reset the response-parser
/// state. Returns `error.Reconnect` on a failed reconnect so the
/// caller can exit its loop cleanly. Centralizes the
/// recover-from-failure path per TIGER_STYLE "centralize control
/// flow."
fn reconnect(
    ctx: *ClientContext,
    stream: *std.net.Stream,
    recv_state: *ResponseParser,
) !void {
    assert(ctx.errors > 0); // caller must have recorded the triggering error
    stream.close();
    stream.* = try std.net.tcpConnectToAddress(ctx.addr);
    recv_state.* = .{};
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

// --- HTTP request sender ---

fn send_request(stream: *std.net.Stream, op: Operation, body: []const u8) !void {
    assert(body.len <= body_max);

    const method_path: MethodPath = switch (op) {
        .create_product => .{ .method = "POST", .path = "/products" },
        .list_products => .{ .method = "GET", .path = "/products" },
        else => unreachable, // rejected at --ops parse
    };
    assert(method_path.method.len > 0);
    assert(method_path.path.len > 0);

    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
        .{ method_path.method, method_path.path, body.len },
    );
    assert(header.len > 0);
    assert(header.len <= header_buf.len);
    try stream.writeAll(header);
    if (body.len > 0) try stream.writeAll(body);
}

const MethodPath = struct { method: []const u8, path: []const u8 };

// --- HTTP response parser ---
//
// Minimal HTTP/1.1 response parser. Handles: status line, headers,
// Content-Length body, keep-alive state across requests, partial
// reads across multiple recv() calls. Written fresh because
// std.http.Client's implicit connection pooling would conflate
// framework-under-load with stdlib-client-under-load.

const ResponseParser = struct {
    /// Leftover bytes from a previous response (start of next).
    /// Keep-alive reuses the stream; recv may read into this.
    leftover: [recv_buf_size]u8 = undefined,
    leftover_len: usize = 0,
};

fn recv_response(
    stream: *std.net.Stream,
    buf: *[recv_buf_size]u8,
    state: *ResponseParser,
) !u16 {
    assert(state.leftover_len <= state.leftover.len);

    // Merge leftover + read loop until we have full response.
    var total_len: usize = state.leftover_len;
    if (state.leftover_len > 0) {
        @memcpy(buf[0..state.leftover_len], state.leftover[0..state.leftover_len]);
        state.leftover_len = 0;
    }
    assert(total_len <= buf.len);

    // Read until we have headers + the advertised body.
    var header_end: ?usize = null;
    var content_length: ?usize = null;
    while (true) {
        assert(total_len <= buf.len);
        if (header_end == null) {
            header_end = std.mem.indexOf(u8, buf[0..total_len], "\r\n\r\n");
        }
        if (header_end) |header_end_pos| {
            assert(header_end_pos + 4 <= buf.len);
            if (content_length == null) {
                content_length = parse_content_length(buf[0..header_end_pos]) orelse
                    return error.NoContentLength;
            }
            // No assert on content_length: unbounded parse at the
            // parser layer. The read-loop below catches oversized
            // bodies via ResponseTooLarge when total_len saturates.
            const body_start = header_end_pos + 4;
            const body_end = body_start + content_length.?;
            if (total_len >= body_end) {
                assert(body_end <= buf.len);
                // Full response in buf. Stash anything past body_end as leftover.
                const extra = total_len - body_end;
                assert(extra <= state.leftover.len);
                if (extra > 0) {
                    @memcpy(state.leftover[0..extra], buf[body_end..total_len]);
                    state.leftover_len = extra;
                }
                return parse_status_line(buf[0..header_end_pos]) orelse
                    return error.BadStatusLine;
            }
        }
        // Need more bytes.
        if (total_len == buf.len) return error.ResponseTooLarge;
        const n = try stream.read(buf[total_len..]);
        if (n == 0) return error.UnexpectedClose;
        total_len += n;
        assert(total_len <= buf.len);
    }
}

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
    // Upper bound isn't enforced here — the read loop in
    // `recv_response` returns `ResponseTooLarge` naturally when a
    // Content-Length exceeds `recv_buf_size`. Adding a bound here
    // would short-circuit that flow and mask it behind NoContentLength.
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
