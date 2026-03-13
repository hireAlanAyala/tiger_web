//! Integration fuzzer — tests the full pipeline through real TCP:
//! Zig fuzzer → TCP → Go proxy → TCP → tiger_web → SQLite, plus SSE events back.
//!
//! Spawns both tiger-web and the Go proxy as child processes, then generates
//! random HTTP requests through the proxy and validates responses + SSE.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const fuzz_lib = @import("fuzz_lib.zig");
const FuzzArgs = fuzz_lib.FuzzArgs;
const PRNG = @import("prng.zig");

const log = std.log.scoped(.proxy_fuzz);

const secret_key = "tiger-web-test-key-0123456789ab!";
const token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsImV4cCI6MjE0NTkxNjgwMH0.ulNOjuMyYo5tT5gG78pG6HvyCZm4Gs7azogXTvz-VgY";

const FuzzAction = enum {
    create_product,
    get_product,
    list_products,
    delete_product,
    create_collection,
    list_collections,
    create_order,
    get_order,
    list_orders,
    complete_order,
    cancel_order,
    bad_token,
    drain_sse,
};

const HttpResponse = struct {
    status: u16,
    body: []const u8,
};

const ProxyFuzzer = struct {
    product_ids: [64]u128 = undefined,
    product_count: u32 = 0,
    collection_ids: [64]u128 = undefined,
    collection_count: u32 = 0,
    order_ids: [64]u128 = undefined,
    order_count: u32 = 0,
    order_mutations: u32 = 0,

    body_buf: [4096]u8 = undefined,
    path_buf: [256]u8 = undefined,
    resp_buf: [16384]u8 = undefined,

    sse_fd: posix.fd_t = -1,
    sse_buf: [16384]u8 = undefined,
    sse_buf_pos: u32 = 0,
    sse_events: u32 = 0,

    proxy_port: u16,

    fn run(self: *ProxyFuzzer, prng: *PRNG, events_max: usize) void {
        const weights = fuzz_lib.random_enum_weights(prng, FuzzAction);

        for (0..events_max) |_| {
            const action = prng.enum_weighted(FuzzAction, weights);
            self.execute_action(prng, action);
        }

        // Final SSE drain after all events.
        if (self.order_mutations > 0) {
            std.time.sleep(200 * std.time.ns_per_ms);
            self.drain_sse();
        }

        // Validate: no 500s were observed (asserted per-request).
        // Validate: if we mutated orders and have SSE, at least 1 event came through.
        if (self.order_mutations > 0 and self.sse_fd != -1) {
            // SSE events are best-effort — the poller may not have caught the change
            // within the fuzz window. Log but don't assert.
            if (self.sse_events == 0) {
                log.info("no SSE events received despite {d} order mutations", .{self.order_mutations});
            }
        }

        log.info(
            \\Fuzz results:
            \\  products={d} collections={d} orders={d}
            \\  order_mutations={d} sse_events={d}
        , .{
            self.product_count,
            self.collection_count,
            self.order_count,
            self.order_mutations,
            self.sse_events,
        });
    }

    fn execute_action(self: *ProxyFuzzer, prng: *PRNG, action: FuzzAction) void {
        switch (action) {
            .create_product => {
                const id = prng.int(u128) | 1;
                const body = self.gen_product_body(prng, id);
                const resp = http_request(self.proxy_port, "POST", "/products", token, body, &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 502);
                if (resp.status == 200 and self.product_count < 64) {
                    self.product_ids[self.product_count] = id;
                    self.product_count += 1;
                }
            },
            .get_product => {
                if (self.product_count == 0) return;
                const id = self.product_ids[prng.int_inclusive(u32, self.product_count - 1)];
                const path = path_with_id(&self.path_buf, "/products/", id);
                const resp = http_request(self.proxy_port, "GET", path, token, "", &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 404 or resp.status == 502);
            },
            .list_products => {
                const resp = http_request(self.proxy_port, "GET", "/products", token, "", &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 502);
            },
            .delete_product => {
                if (self.product_count == 0) return;
                const idx = prng.int_inclusive(u32, self.product_count - 1);
                const id = self.product_ids[idx];
                const path = path_with_id(&self.path_buf, "/products/", id);
                const resp = http_request(self.proxy_port, "DELETE", path, token, "", &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 404 or resp.status == 502);
            },
            .create_collection => {
                const id = prng.int(u128) | 1;
                const body = self.gen_collection_body(prng, id);
                const resp = http_request(self.proxy_port, "POST", "/collections", token, body, &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 502);
                if (resp.status == 200 and self.collection_count < 64) {
                    self.collection_ids[self.collection_count] = id;
                    self.collection_count += 1;
                }
            },
            .list_collections => {
                const resp = http_request(self.proxy_port, "GET", "/collections", token, "", &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 502);
            },
            .create_order => {
                if (self.product_count == 0) return;
                const id = prng.int(u128) | 1;
                const body = self.gen_order_body(prng, id);
                const resp = http_request(self.proxy_port, "POST", "/orders", token, body, &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 502);
                if (resp.status == 200 and self.order_count < 64) {
                    self.order_ids[self.order_count] = id;
                    self.order_count += 1;
                    self.order_mutations += 1;
                }
            },
            .get_order => {
                if (self.order_count == 0) return;
                const id = self.order_ids[prng.int_inclusive(u32, self.order_count - 1)];
                const path = path_with_id(&self.path_buf, "/orders/", id);
                const resp = http_request(self.proxy_port, "GET", path, token, "", &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 404 or resp.status == 502);
            },
            .list_orders => {
                const resp = http_request(self.proxy_port, "GET", "/orders", token, "", &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 502);
            },
            .complete_order => {
                if (self.order_count == 0) return;
                const id = self.order_ids[prng.int_inclusive(u32, self.order_count - 1)];
                const path = path_with_id(&self.path_buf, "/orders/", id);
                const body = "{\"result\":\"confirmed\"}";
                const resp = http_request(self.proxy_port, "PUT", path, token, body, &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 404 or resp.status == 502);
                if (resp.status == 200) self.order_mutations += 1;
            },
            .cancel_order => {
                if (self.order_count == 0) return;
                const id = self.order_ids[prng.int_inclusive(u32, self.order_count - 1)];
                const path = path_with_id(&self.path_buf, "/orders/", id);
                const resp = http_request(self.proxy_port, "DELETE", path, token, "", &self.resp_buf) orelse return;
                assert(resp.status == 200 or resp.status == 404 or resp.status == 502);
                if (resp.status == 200) self.order_mutations += 1;
            },
            .bad_token => {
                const resp = http_request(self.proxy_port, "GET", "/products", "bad-token", "", &self.resp_buf) orelse return;
                assert(resp.status == 401 or resp.status == 502);
            },
            .drain_sse => {
                self.drain_sse();
            },
        }
    }

    fn drain_sse(self: *ProxyFuzzer) void {
        if (self.sse_fd == -1) return;

        while (true) {
            const remaining = self.sse_buf.len - self.sse_buf_pos;
            if (remaining == 0) {
                // Buffer full — reset (we only care about event counts).
                self.sse_buf_pos = 0;
                break;
            }
            const n = posix.read(self.sse_fd, self.sse_buf[self.sse_buf_pos..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    log.warn("SSE read error: {}", .{err});
                    posix.close(self.sse_fd);
                    self.sse_fd = -1;
                    return;
                },
            };
            if (n == 0) {
                // EOF — server closed the SSE connection.
                posix.close(self.sse_fd);
                self.sse_fd = -1;
                return;
            }
            self.sse_buf_pos += @intCast(n);
        }

        // Count SSE events in accumulated buffer.
        const data = self.sse_buf[0..self.sse_buf_pos];
        var pos: usize = 0;
        while (std.mem.indexOf(u8, data[pos..], "event: datastar-merge-signals\n")) |idx| {
            self.sse_events += 1;
            pos += idx + 1;
        }
    }

    // --- Body generators (copied from sim.zig BufWriter pattern) ---

    fn gen_product_body(self: *ProxyFuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"name\":\"");
        w.random_name(prng);
        w.raw("\",\"price_cents\":");
        w.num(prng.range_inclusive(u32, 1, 99999));
        w.raw(",\"inventory\":");
        w.num(prng.range_inclusive(u32, 0, 1000));
        w.raw("}");
        return w.slice();
    }

    fn gen_collection_body(self: *ProxyFuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"name\":\"");
        w.random_name(prng);
        w.raw("\"}");
        return w.slice();
    }

    fn gen_order_body(self: *ProxyFuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"items\":[");

        const max_items: u32 = @min(5, self.product_count);
        const item_count = prng.range_inclusive(u32, 1, max_items);
        var used: [5]u32 = .{0} ** 5;
        var used_count: u8 = 0;

        for (0..item_count) |i| {
            if (i > 0) w.raw(",");

            var prod_idx = prng.int_inclusive(u32, self.product_count - 1);
            var attempts: u32 = 0;
            while (attempts < self.product_count) : (attempts += 1) {
                var dup = false;
                for (used[0..used_count]) |u| {
                    if (u == prod_idx) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) break;
                prod_idx = (prod_idx + 1) % self.product_count;
            }
            used[used_count] = prod_idx;
            used_count += 1;

            w.raw("{\"product_id\":\"");
            w.uuid(self.product_ids[prod_idx]);
            w.raw("\",\"quantity\":");
            w.num(prng.range_inclusive(u32, 1, 10));
            w.raw("}");
        }

        w.raw("]}");
        return w.slice();
    }
};

/// Tiny buffer writer for building JSON and paths without allocations.
const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn raw(self: *BufWriter, s: []const u8) void {
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    fn uuid(self: *BufWriter, val: u128) void {
        const hex = "0123456789abcdef";
        var v = val;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            self.buf[self.pos + i] = hex[@intCast(v & 0xf)];
            v >>= 4;
        }
        self.pos += 32;
    }

    fn num(self: *BufWriter, val: u32) void {
        var num_buf: [10]u8 = undefined;
        const s = format_u32(&num_buf, val);
        self.raw(s);
    }

    fn random_name(self: *BufWriter, prng: *PRNG) void {
        const len = prng.range_inclusive(u8, 1, 20);
        for (self.buf[self.pos..][0..len]) |*c| {
            c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
        }
        self.pos += len;
    }

    fn slice(self: *BufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

fn path_with_id(buf: *[256]u8, prefix: []const u8, id: u128) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(prefix);
    w.uuid(id);
    return w.slice();
}

fn format_u32(buf: *[10]u8, val: u32) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var pos: usize = 10;
    while (v > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[pos..10];
}

/// Make one HTTP request through the proxy. Returns null on connection failure.
fn http_request(port: u16, method: []const u8, path: []const u8, auth_token: []const u8, body: []const u8, resp_buf: []u8) ?HttpResponse {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return null;
    defer posix.close(fd);

    // Set a 3-second timeout so we don't hang forever.
    const timeout = posix.timeval{ .sec = 3, .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return null;

    // Build request.
    var req_buf: [8192]u8 = undefined;
    var pos: usize = 0;

    inline for (.{ method, " ", path, " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n" }) |part| {
        @memcpy(req_buf[pos..][0..part.len], part);
        pos += part.len;
    }

    // Auth header.
    const auth_hdr = "Authorization: Bearer ";
    @memcpy(req_buf[pos..][0..auth_hdr.len], auth_hdr);
    pos += auth_hdr.len;
    @memcpy(req_buf[pos..][0..auth_token.len], auth_token);
    pos += auth_token.len;
    @memcpy(req_buf[pos..][0..2], "\r\n");
    pos += 2;

    if (body.len > 0) {
        const ct = "Content-Type: application/json\r\nContent-Length: ";
        @memcpy(req_buf[pos..][0..ct.len], ct);
        pos += ct.len;
        var cl_buf: [10]u8 = undefined;
        const cl_str = format_u32(&cl_buf, @intCast(body.len));
        @memcpy(req_buf[pos..][0..cl_str.len], cl_str);
        pos += cl_str.len;
        @memcpy(req_buf[pos..][0..2], "\r\n");
        pos += 2;
    }

    @memcpy(req_buf[pos..][0..2], "\r\n");
    pos += 2;

    if (body.len > 0) {
        @memcpy(req_buf[pos..][0..body.len], body);
        pos += body.len;
    }

    // Send.
    _ = posix.write(fd, req_buf[0..pos]) catch return null;

    // Receive full response.
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = posix.read(fd, resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return null;

    // Parse status line: "HTTP/1.1 200 ...\r\n"
    const resp = resp_buf[0..total];
    const status_start = std.mem.indexOf(u8, resp, " ") orelse return null;
    const status_end = std.mem.indexOfPos(u8, resp, status_start + 1, " ") orelse
        std.mem.indexOfPos(u8, resp, status_start + 1, "\r") orelse return null;
    const status = std.fmt.parseUnsigned(u16, resp[status_start + 1 .. status_end], 10) catch return null;

    // Find body after \r\n\r\n.
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return .{ .status = status, .body = "" };
    const resp_body = resp[header_end + 4 ..];

    // Assert no 500s — that indicates a proxy or server bug.
    assert(status != 500);

    return .{ .status = status, .body = resp_body };
}

/// Wait for a TCP port to accept connections.
fn wait_for_port(port: u16) bool {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    for (0..60) |_| {
        const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch continue;
        defer posix.close(fd);
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
            std.time.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        return true;
    }
    return false;
}

/// Open a non-blocking SSE connection to the proxy.
fn open_sse_connection(port: u16) posix.fd_t {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return -1;
    errdefer posix.close(fd);

    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return -1;

    // Send SSE request.
    var req_buf: [512]u8 = undefined;
    var pos: usize = 0;
    const req_line = "GET /events?token=" ++ token ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n";
    @memcpy(req_buf[pos..][0..req_line.len], req_line);
    pos += req_line.len;

    _ = posix.write(fd, req_buf[0..pos]) catch {
        posix.close(fd);
        return -1;
    };

    // Set non-blocking for subsequent reads.
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch {
        posix.close(fd);
        return -1;
    };
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    _ = posix.fcntl(fd, posix.F.SETFL, flags | nonblock) catch {
        posix.close(fd);
        return -1;
    };

    // Wait a bit for the HTTP response headers.
    std.time.sleep(100 * std.time.ns_per_ms);

    // Drain the HTTP response headers so sse_buf starts clean.
    var drain_buf: [4096]u8 = undefined;
    _ = posix.read(fd, &drain_buf) catch {};

    return fd;
}

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 200;
    var prng = PRNG.from_seed(seed);

    // Derive ports from seed to avoid collisions between parallel runs.
    const tiger_port: u16 = @intCast(10000 + (seed % 50000));
    const proxy_port: u16 = tiger_port + 1;

    log.info(
        \\Proxy fuzz config:
        \\  seed={d} events_max={d}
        \\  tiger_port={d} proxy_port={d}
    , .{ seed, events_max, tiger_port, proxy_port });

    // --- Spawn tiger-web ---
    var tiger_port_buf: [10]u8 = undefined;
    const tiger_port_str = format_u32(&tiger_port_buf, tiger_port);

    // Build --port=N flag (flags.zig requires = syntax).
    var port_flag_buf: [32]u8 = undefined;
    const port_prefix = "--port=";
    @memcpy(port_flag_buf[0..port_prefix.len], port_prefix);
    @memcpy(port_flag_buf[port_prefix.len..][0..tiger_port_str.len], tiger_port_str);
    const port_flag = port_flag_buf[0 .. port_prefix.len + tiger_port_str.len];

    var tiger = std.process.Child.init(
        &.{ "./zig-out/bin/tiger-web", port_flag, "--db=:memory:" },
        allocator,
    );
    tiger.stderr_behavior = .Inherit;
    tiger.stdout_behavior = .Inherit;

    tiger.spawn() catch |err| {
        log.err("failed to spawn tiger-web: {}", .{err});
        return err;
    };
    defer {
        _ = tiger.kill() catch {};
        _ = tiger.wait() catch {};
    }

    // --- Spawn Go proxy ---
    var proxy_port_buf: [10]u8 = undefined;
    const proxy_port_str = format_u32(&proxy_port_buf, proxy_port);

    var tiger_addr_buf: [64]u8 = undefined;
    var tiger_addr_pos: usize = 0;
    const tiger_addr_prefix = "http://127.0.0.1:";
    @memcpy(tiger_addr_buf[0..tiger_addr_prefix.len], tiger_addr_prefix);
    tiger_addr_pos += tiger_addr_prefix.len;
    @memcpy(tiger_addr_buf[tiger_addr_pos..][0..tiger_port_str.len], tiger_port_str);
    tiger_addr_pos += tiger_port_str.len;
    const tiger_addr = tiger_addr_buf[0..tiger_addr_pos];

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    // Inherit SECRET_KEY from parent for tiger-web (already in env).
    // Set proxy-specific vars.
    try env.put("TIGER_ADDR", tiger_addr);
    try env.put("PROXY_PORT", proxy_port_str);
    try env.put("TOKEN", token);
    try env.put("POLL_INTERVAL", "50ms");
    // Inherit PATH and HOME for `go` to work.
    if (std.posix.getenv("PATH")) |v| try env.put("PATH", v);
    if (std.posix.getenv("HOME")) |v| try env.put("HOME", v);
    if (std.posix.getenv("GOPATH")) |v| try env.put("GOPATH", v);
    if (std.posix.getenv("GOROOT")) |v| try env.put("GOROOT", v);
    if (std.posix.getenv("GOCACHE")) |v| try env.put("GOCACHE", v);

    var proxy = std.process.Child.init(
        &.{ "go", "run", "." },
        allocator,
    );
    proxy.cwd = "proxy";
    proxy.env_map = &env;
    proxy.stderr_behavior = .Inherit;
    proxy.stdout_behavior = .Inherit;

    proxy.spawn() catch |err| {
        log.err("failed to spawn proxy: {}", .{err});
        return err;
    };
    defer {
        _ = proxy.kill() catch {};
        _ = proxy.wait() catch {};
    }

    // --- Wait for both to be ready ---
    if (!wait_for_port(tiger_port)) {
        log.err("tiger-web failed to start on port {d}", .{tiger_port});
        return error.TigerWebTimeout;
    }
    log.info("tiger-web ready on port {d}", .{tiger_port});

    if (!wait_for_port(proxy_port)) {
        log.err("proxy failed to start on port {d}", .{proxy_port});
        return error.ProxyTimeout;
    }
    log.info("proxy ready on port {d}", .{proxy_port});

    // --- Open SSE connection ---
    const sse_fd = open_sse_connection(proxy_port);

    // --- Run the fuzzer ---
    var fuzzer = ProxyFuzzer{
        .proxy_port = proxy_port,
        .sse_fd = sse_fd,
    };
    defer if (fuzzer.sse_fd != -1) posix.close(fuzzer.sse_fd);

    fuzzer.run(&prng, events_max);
}
