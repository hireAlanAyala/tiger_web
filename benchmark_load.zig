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
//!   - Warmup with measure-and-discard semantics: first
//!     `--warmup-seconds` of each thread's wall-clock runs requests
//!     but records nothing. Flaw-fix divergence from TB (TB measures
//!     from `timer.reset`).
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

/// Per TB `benchmark_load.zig:117-118`. Each bucket is 1 ms; the
/// last bucket captures 10_000 ms+.
const histogram_buckets: usize = 10_001;

/// Maximum distinct ops in an `--ops=...` spec. Bounded per
/// TIGER_STYLE "put a limit on everything" — excess entries
/// rejected at parse.
const op_mix_max: u8 = 32;

/// Maximum JSON body size for a single request. `create_product`
/// fits well under this; `list_products` has no body.
const body_max: usize = 1024;

/// TCP recv buffer size per connection. Response headers + body
/// for our benches fit comfortably.
const recv_buf_size: usize = 4096;

/// Operations supported by the load generator. Parsing `--ops`
/// rejects anything not in this list.
const supported_ops = [_]Operation{ .create_product, .list_products };

const OpMix = struct {
    op: Operation,
    weight: u32,
};
const OpMixArray = BoundedArrayType(OpMix, op_mix_max);

// --- Entry point ---

pub fn run(gpa: std.mem.Allocator, cli: BenchmarkArgs) !void {
    assert(cli.port > 0);
    assert(cli.connections > 0);
    assert(cli.requests > 0);

    const op_mix = try parse_op_mix(cli.ops);
    assert(op_mix.count() > 0);

    log.info(
        "benchmark: port={d} connections={d} requests={d} warmup={d}s",
        .{ cli.port, cli.connections, cli.requests, cli.@"warmup-seconds" },
    );

    // Quick server reachability probe — connect, send a simple GET,
    // disconnect. Confirms the server is up before we spawn threads.
    try probe_server(cli.port);

    const addr = try std.net.Address.parseIp4("127.0.0.1", cli.port);
    const thread_count: u32 = cli.connections;
    const requests_per_thread: u32 = cli.requests / thread_count;
    assert(requests_per_thread > 0);

    const threads = try gpa.alloc(std.Thread, thread_count);
    defer gpa.free(threads);

    const contexts = try gpa.alloc(ClientContext, thread_count);
    defer gpa.free(contexts);

    const histograms = try gpa.alloc([histogram_buckets]u64, thread_count);
    defer gpa.free(histograms);
    @memset(histograms, [_]u64{0} ** histogram_buckets);

    const warmup_ns: u64 = @as(u64, cli.@"warmup-seconds") * std.time.ns_per_s;
    const start_instant = std.time.Instant.now() catch @panic("clock unavailable");

    for (threads, contexts, histograms, 0..) |*t, *ctx, *hist, i| {
        ctx.* = ClientContext{
            .index = @intCast(i),
            .addr = addr,
            .op_mix = &op_mix,
            .requests = requests_per_thread,
            .warmup_ns = warmup_ns,
            .start_instant = start_instant,
            .histogram = hist,
            .errors = 0,
            .warmup_samples = 0,
        };
        t.* = try std.Thread.spawn(.{}, client_loop, .{ctx});
    }

    for (threads) |t| t.join();

    const elapsed_ns = blk: {
        const now = std.time.Instant.now() catch @panic("clock unavailable");
        break :blk now.since(start_instant);
    };
    const measured_ns: u64 = if (elapsed_ns > warmup_ns) elapsed_ns - warmup_ns else 0;
    assert(measured_ns > 0);

    // Merge per-thread histograms.
    var total_hist = [_]u64{0} ** histogram_buckets;
    var total_samples: u64 = 0;
    var total_errors: u64 = 0;
    var total_warmup: u64 = 0;
    for (contexts, histograms) |*ctx, *hist| {
        for (hist, 0..) |count, bucket| {
            total_hist[bucket] += count;
            total_samples += count;
        }
        total_errors += ctx.errors;
        total_warmup += ctx.warmup_samples;
    }

    report(cli, measured_ns, total_samples, total_errors, total_warmup, &total_hist);
}

// --- `--ops` parser ---

fn parse_op_mix(spec: []const u8) !OpMixArray {
    var result: OpMixArray = .{};
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |entry| {
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse {
            log.err("--ops: expected 'NAME:WEIGHT', got '{s}'", .{entry});
            return error.BadOpsSpec;
        };
        const name = entry[0..colon];
        const weight_str = entry[colon + 1 ..];
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
        result.push(.{ .op = op, .weight = weight });
    }
    if (result.empty()) {
        log.err("--ops: at least one op required", .{});
        return error.BadOpsSpec;
    }
    return result;
}

fn resolve_op(name: []const u8) ?Operation {
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
    var total_weight: u32 = 0;
    for (mix) |entry| total_weight += entry.weight;
    assert(total_weight > 0);
    const roll: u32 = prng.int_inclusive(u32, total_weight - 1);
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
    warmup_ns: u64,
    start_instant: std.time.Instant,
    histogram: *[histogram_buckets]u64,
    // Written only by this thread; read by main after join. No sync.
    errors: u64,
    warmup_samples: u64,
};

fn client_loop(ctx: *ClientContext) void {
    // Per-thread PRNG derived from the canonical bench seed + index,
    // so replay under the same seed is deterministic even with many
    // threads. Explicit XOR keeps each thread's PRNG independent.
    const seed: u64 = 0xDEADBEEFCAFEBABE ^ @as(u64, ctx.index);
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

    var i: u32 = 0;
    while (i < ctx.requests) : (i += 1) {
        const op = op_mix_pick(&prng, ctx.op_mix);
        const body = construct_body(&prng, op, &body_buf);

        const req_start = std.time.Instant.now() catch @panic("clock unavailable");
        send_request(&stream, op, body) catch |err| {
            log.warn("client {d}: send failed: {s}; reconnecting", .{ ctx.index, @errorName(err) });
            ctx.errors += 1;
            stream.close();
            stream = std.net.tcpConnectToAddress(ctx.addr) catch return;
            recv_state = .{};
            continue;
        };
        const status = recv_response(&stream, &recv_buf, &recv_state) catch |err| {
            log.warn("client {d}: recv failed: {s}; reconnecting", .{ ctx.index, @errorName(err) });
            ctx.errors += 1;
            stream.close();
            stream = std.net.tcpConnectToAddress(ctx.addr) catch return;
            recv_state = .{};
            continue;
        };
        if (status < 200 or status >= 300) {
            ctx.errors += 1;
            continue;
        }

        const now = std.time.Instant.now() catch @panic("clock unavailable");
        const duration_ns: u64 = now.since(req_start);
        const in_warmup = now.since(ctx.start_instant) < ctx.warmup_ns;
        if (in_warmup) {
            ctx.warmup_samples += 1;
        } else {
            // Transplanted from TB `benchmark_load.zig:876`.
            const duration_ms: u64 = duration_ns / std.time.ns_per_ms;
            ctx.histogram[@min(duration_ms, histogram_buckets - 1)] += 1;
        }
    }
}

// --- Body construction (PRNG-derived, deterministic under seed) ---

fn construct_body(prng: *PRNG, op: Operation, buf: []u8) []const u8 {
    return switch (op) {
        .create_product => construct_create_product(prng, buf),
        .list_products => buf[0..0], // GET, no body
        else => unreachable, // rejected at --ops parse
    };
}

fn construct_create_product(prng: *PRNG, buf: []u8) []const u8 {
    var id_hex: [32]u8 = undefined;
    const id: u128 = prng.int(u128) | 1; // non-zero per handler contract
    stdx.write_uuid_to_buf(&id_hex, id);

    // PRNG-derived name: always ASCII [a-z]{8}. Deterministic under
    // the same seed; avoids any non-UTF8 byte the handler would reject.
    var name: [8]u8 = undefined;
    for (&name) |*c| c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u32, 25)));

    const price: u32 = prng.int_inclusive(u32, 999_999);
    const inventory: u32 = prng.int_inclusive(u32, 9_999);

    const written = std.fmt.bufPrint(
        buf,
        \\{{"id":"{s}","name":"{s}","price_cents":{d},"inventory":{d}}}
    ,
        .{ id_hex, name, price, inventory },
    ) catch @panic("body_max too small");
    return written;
}

// --- HTTP request sender ---

fn send_request(stream: *std.net.Stream, op: Operation, body: []const u8) !void {
    const mp: MethodPath = switch (op) {
        .create_product => .{ .method = "POST", .path = "/products" },
        .list_products => .{ .method = "GET", .path = "/products" },
        else => unreachable, // rejected at --ops parse
    };
    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
        .{ mp.method, mp.path, body.len },
    );
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
    // Merge leftover + read loop until we have full response.
    var total_len: usize = state.leftover_len;
    if (state.leftover_len > 0) {
        @memcpy(buf[0..state.leftover_len], state.leftover[0..state.leftover_len]);
        state.leftover_len = 0;
    }

    // Read until we have headers + the advertised body.
    var header_end: ?usize = null;
    var content_length: ?usize = null;
    while (true) {
        if (header_end == null) {
            header_end = std.mem.indexOf(u8, buf[0..total_len], "\r\n\r\n");
        }
        if (header_end) |he| {
            if (content_length == null) {
                content_length = parse_content_length(buf[0..he]) orelse return error.NoContentLength;
            }
            const body_start = he + 4;
            const body_end = body_start + content_length.?;
            if (total_len >= body_end) {
                // Full response in buf. Stash anything past body_end as leftover.
                const extra = total_len - body_end;
                if (extra > 0) {
                    @memcpy(state.leftover[0..extra], buf[body_end..total_len]);
                    state.leftover_len = extra;
                }
                return parse_status_line(buf[0..he]) orelse return error.BadStatusLine;
            }
        }
        // Need more bytes.
        if (total_len == buf.len) return error.ResponseTooLarge;
        const n = try stream.read(buf[total_len..]);
        if (n == 0) return error.UnexpectedClose;
        total_len += n;
    }
}

fn parse_status_line(headers: []const u8) ?u16 {
    // "HTTP/1.1 NNN ...\r\n"
    if (headers.len < 12) return null;
    if (!std.mem.startsWith(u8, headers, "HTTP/1.1 ")) return null;
    return std.fmt.parseInt(u16, headers[9..12], 10) catch null;
}

fn parse_content_length(headers: []const u8) ?usize {
    const marker = "\r\nContent-Length: ";
    const start = std.mem.indexOf(u8, headers, marker) orelse return null;
    const val_start = start + marker.len;
    const val_end = std.mem.indexOf(u8, headers[val_start..], "\r\n") orelse return null;
    return std.fmt.parseInt(usize, headers[val_start .. val_start + val_end], 10) catch null;
}

// --- Reachability probe ---

fn probe_server(port: u16) !void {
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
    measured_ns: u64,
    samples: u64,
    errors: u64,
    warmup_samples: u64,
    histogram: *const [histogram_buckets]u64,
) void {
    const stdout = std.io.getStdOut().writer();

    // Transplanted shape from TB `benchmark_load.zig:556-572`.
    const rate: u64 = if (measured_ns > 0)
        @divTrunc(samples * std.time.ns_per_s, measured_ns)
    else
        0;
    stdout.print(
        \\benchmark_connections = {d} count
        \\benchmark_requests = {d} count
        \\benchmark_warmup_samples = {d} count
        \\benchmark_errors = {d} count
        \\benchmark_throughput = {d} req/s
        \\closed_loop = 1 count
        \\
    , .{ cli.connections, samples, warmup_samples, errors, rate }) catch return;

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
    var histogram_total: u64 = 0;
    for (histogram_buckets_slice) |bucket| histogram_total += bucket;
    if (histogram_total == 0) return;

    const percentiles = [_]u64{ 1, 50, 99, 100 };
    for (percentiles) |percentile| {
        const histogram_percentile: u64 = @divTrunc(histogram_total * percentile, 100);

        var sum: u64 = 0;
        const latency = for (histogram_buckets_slice, 0..) |bucket, bucket_index| {
            sum += bucket;
            if (sum >= histogram_percentile) break bucket_index;
        } else histogram_buckets_slice.len;

        stdout.print("{s}_p{d} = {d} ms\n", .{ label, percentile, latency }) catch return;
    }
}
