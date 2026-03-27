//! HTTP load generator — workload generation, measurement, and reporting.
//!
//! Connects N persistent HTTP clients to a running tiger-web server,
//! sends PRNG-driven mixed workloads across keep-alive connections,
//! and measures per-operation latency via histograms. Follows
//! TigerBeetle's benchmark_load.zig patterns: stage-based progression,
//! per-request timing snapshots, 1ms-bucket histograms, zero error budget.
//!
//! Imports message.zig only for the comptime Operation ↔ LoadOp assertion
//! (forces the developer to update the load test when operations change).
//! No runtime dependency on application modules — the load generator is a
//! pure HTTP client that exercises the full stack.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;
const stdx = @import("stdx");
const PRNG = stdx.PRNG;
const IO = @import("framework/io.zig").IO;

const log = std.log.scoped(.load_gen);

/// Operations exercised by the load test. Subset of the full operation enum —
/// excludes auth, pages, and operations that require multi-step flows.
pub const LoadOp = enum(u8) {
    create_product = 0,
    get_product = 1,
    list_products = 2,
    create_collection = 3,
    get_collection = 4,
    list_collections = 5,
    create_order = 6,
    get_order = 7,
    list_orders = 8,

    fn is_create(op: LoadOp) bool {
        return switch (op) {
            .create_product, .create_collection, .create_order => true,
            else => false,
        };
    }
};

const load_op_count = @typeInfo(LoadOp).@"enum".fields.len;

const message = @import("message.zig");

comptime {
    // Every Operation must either have a LoadOp or be explicitly excluded.
    // If you add a new operation to message.zig, the build breaks here —
    // you must decide whether the load test exercises it.
    const excluded = .{
        message.Operation.root,
        message.Operation.page_load_dashboard,
        message.Operation.page_load_login,
        message.Operation.request_login_code,
        message.Operation.verify_login_code,
        message.Operation.logout,
        message.Operation.update_product,
        message.Operation.delete_product,
        message.Operation.delete_collection,
        message.Operation.add_collection_member,
        message.Operation.remove_collection_member,
        message.Operation.transfer_inventory,
        message.Operation.complete_order,
        message.Operation.cancel_order,
        message.Operation.get_product_inventory,
        message.Operation.search_products,
    };

    for (@typeInfo(message.Operation).@"enum".fields) |field| {
        const op: message.Operation = @enumFromInt(field.value);
        var is_excluded = false;
        for (excluded) |ex| {
            if (op == ex) {
                is_excluded = true;
                break;
            }
        }
        if (is_excluded) continue;

        var found = false;
        for (@typeInfo(LoadOp).@"enum".fields) |lf| {
            if (std.mem.eql(u8, lf.name, field.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("Operation." ++ field.name ++ " is not in LoadOp and not in the exclusion list — add it to one");
        }
    }
}

/// Operation weights — configurable via --ops CLI flag.
/// Default: representative read-heavy web workload.
pub const Weights = PRNG.EnumWeightsType(LoadOp);

pub const default_weights: Weights = .{
    .create_product = 15,
    .get_product = 25,
    .list_products = 15,
    .create_collection = 5,
    .get_collection = 10,
    .list_collections = 5,
    .create_order = 10,
    .get_order = 10,
    .list_orders = 5,
};

/// Custom weight parsing for the --ops CLI flag.
/// Format: "create_product:30,list_products:50,create_order:20"
/// Unspecified operations get weight 0 (disabled).
/// Uses TB's parse_flag_value customization point.
pub const OpsFlag = struct {
    weights: Weights,

    pub fn parse_flag_value(
        value: []const u8,
        diagnostic: *?[]const u8,
    ) error{InvalidFlagValue}!OpsFlag {
        var weights = std.mem.zeroes(Weights);
        var pos: usize = 0;

        while (pos < value.len) {
            // Find operation name.
            const colon = std.mem.indexOfPos(u8, value, pos, ":") orelse {
                diagnostic.* = "expected 'operation:weight' format";
                return error.InvalidFlagValue;
            };
            const name = value[pos..colon];

            // Find weight value.
            const comma = std.mem.indexOfPos(u8, value, colon + 1, ",") orelse value.len;
            const weight_str = value[colon + 1 .. comma];

            const weight = std.fmt.parseInt(u32, weight_str, 10) catch {
                diagnostic.* = "weight must be a number";
                return error.InvalidFlagValue;
            };

            // Match operation name.
            var found = false;
            inline for (@typeInfo(LoadOp).@"enum".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    @field(weights, field.name) = weight;
                    found = true;
                }
            }
            if (!found) {
                diagnostic.* = "unknown operation name";
                return error.InvalidFlagValue;
            }

            pos = if (comma < value.len) comma + 1 else value.len;
        }

        // At least one operation must have non-zero weight.
        var any_nonzero = false;
        inline for (@typeInfo(LoadOp).@"enum".fields) |field| {
            if (@field(weights, field.name) > 0) any_nonzero = true;
        }
        if (!any_nonzero) {
            diagnostic.* = "at least one operation must have non-zero weight";
            return error.InvalidFlagValue;
        }

        return .{ .weights = weights };
    }
};

// --- Buffer sizes ---
//
// The format fuzzer validates every formatter's output fits in send_buf_max
// across 90,000 random inputs. No parallel-truth constants — the fuzzer
// is the source of truth for sizing, not hand-calculated maximums.

const send_buf_max = 2048;
const recv_buf_max = 16384;

// --- ID pools ---

const id_pool_capacity = 2048;

// --- Histogram ---

const histogram_bucket_count = 10_001;

pub const max_connections: u16 = 128;

/// Per-connection state. Each connection is an independent HTTP client
/// that alternates between sending requests and receiving responses.
///
/// Owns all per-request context — the connection that formats the request
/// also records its created ID and timing. No shared mutable state.
///
/// Per-connection PRNG — each connection's workload is deterministic
/// given the seed + connection index. Callback ordering (kernel scheduling)
/// does not affect PRNG sequences. Follows TB's per-client state pattern.
const Connection = struct {
    fd: posix.fd_t = -1,
    send_buf: [send_buf_max]u8 = undefined,
    recv_buf: [recv_buf_max]u8 = undefined,
    send_len: u32 = 0,
    send_pos: u32 = 0,
    recv_len: u32 = 0,
    completion: IO.Completion = .{},
    /// Snapshot of timer.read() at send time — per-request, not shared.
    request_start_ns: u64 = 0,
    /// The operation this connection is currently executing.
    current_op: LoadOp = .create_product,
    /// ID of the entity being created by this request. Owned by the
    /// connection, not the LoadGen — eliminates interleaving bugs.
    created_id: u128 = 0,
    state: State = .idle,
    index: u16 = 0,
    /// Per-connection PRNG — seeded from main seed XOR connection index.
    /// Operation selection and payload generation are deterministic per
    /// connection regardless of callback interleaving.
    prng: PRNG = PRNG.from_seed(0),
    /// Back-pointer to the owning LoadGen. Set once at allocation time.
    load: *LoadGen,

    const State = enum {
        idle,
        sending,
        receiving,
    };
};

/// Load generator state. One struct, no globals. Follows TB's Benchmark pattern.
///
/// Heap-allocated via init() — the struct is ~3MB (128 connections with
/// 18KB buffers each, plus histograms and ID pools). Stack allocation
/// would overflow. Connections are embedded inline (no separate allocation)
/// with back-pointers set once at init time.
pub const LoadGen = struct {
    io: *IO,
    timer: std.time.Timer,
    stage: Stage,
    port: u16,

    // Connections — owned inline, back-pointers set at init.
    connections: [max_connections]Connection,
    connections_count: u16,

    // Counters — monotonic. requests_dispatched only increments in
    // dispatch_request. requests_completed only increments in
    // on_response_complete. No decrements, no undo. Error recovery
    // reconnects and goes idle — dispatch_all on next tick re-activates.
    requests_dispatched: u64,
    requests_completed: u64,
    requests_target: u64,
    reconnections: u64,

    // ID pools — fixed capacity, same pattern as fuzz.zig's IdTracker.
    product_ids: [id_pool_capacity]u128,
    product_count: u32,
    collection_ids: [id_pool_capacity]u128,
    collection_count: u32,
    order_ids: [id_pool_capacity]u128,
    order_count: u32,

    // Per-operation histograms (1ms buckets, last = overflow).
    histograms: [load_op_count][histogram_bucket_count]u64,
    // Per-operation request counts (for results table).
    op_counts: [load_op_count]u64,

    // Config
    seed: u64,
    seed_count: u32,
    total_requests: u32,
    do_analysis: bool,
    weights: Weights,

    const Stage = enum {
        seed,
        warmup,
        load,
        done,
    };

    /// Allocate and initialize a LoadGen on the heap. The struct is too
    /// large for the stack (~3MB). Back-pointers from connections to the
    /// LoadGen are set here, once, at allocation time — no fix_pointers.
    pub fn init(
        allocator: std.mem.Allocator,
        io: *IO,
        port: u16,
        connections_count: u16,
        total_requests: u32,
        seed: u64,
        seed_count: u32,
        do_analysis: bool,
        weights: Weights,
    ) *LoadGen {
        assert(connections_count >= 1);
        assert(connections_count <= max_connections);
        assert(total_requests > 0);
        assert(seed_count > 0);

        const self = allocator.create(LoadGen) catch @panic("OOM");
        self.* = .{
            .io = io,
            .timer = std.time.Timer.start() catch unreachable,
            .stage = .seed,
            .port = port,
            .connections = undefined,
            .connections_count = connections_count,
            .requests_dispatched = 0,
            .requests_completed = 0,
            .requests_target = 0,
            .reconnections = 0,
            .product_ids = undefined,
            .product_count = 0,
            .collection_ids = undefined,
            .collection_count = 0,
            .order_ids = undefined,
            .order_count = 0,
            .histograms = std.mem.zeroes([load_op_count][histogram_bucket_count]u64),
            .op_counts = std.mem.zeroes([load_op_count]u64),
            .seed = seed,
            .seed_count = seed_count,
            .total_requests = total_requests,
            .do_analysis = do_analysis,
            .weights = weights,
        };

        // Per-connection PRNG seeded from main seed XOR connection index.
        // Each connection's workload is deterministic regardless of
        // callback ordering. The XOR ensures non-overlapping sequences.
        for (&self.connections, 0..) |*conn, i| {
            conn.* = .{ .load = self };
            conn.index = @intCast(i);
            conn.prng = PRNG.from_seed(seed ^ @as(u64, i));
        }

        return self;
    }

    pub fn deinit(self: *LoadGen, allocator: std.mem.Allocator) void {
        self.close_connections();
        allocator.destroy(self);
    }

    // =================================================================
    // Invariants
    // =================================================================

    /// Structural invariants — checked after every tick in the event loop.
    /// Formalizes the relationship between counters, connection states,
    /// and ID pools. Follows TB's `defer self.invariants()` pattern.
    fn invariants(self: *const LoadGen) void {
        assert(self.requests_completed <= self.requests_dispatched);
        assert(self.stage != .done);

        var busy: u64 = 0;
        for (self.connections[0..self.connections_count]) |*conn| {
            assert(conn.load == self);
            assert(conn.fd >= 0);
            switch (conn.state) {
                .idle => {},
                .sending => {
                    assert(conn.send_pos < conn.send_len);
                    busy += 1;
                },
                .receiving => {
                    assert(conn.recv_len <= recv_buf_max);
                    busy += 1;
                },
            }
        }
        assert(self.requests_dispatched >= self.requests_completed + busy);

        assert(self.product_count <= id_pool_capacity);
        assert(self.collection_count <= id_pool_capacity);
        assert(self.order_count <= id_pool_capacity);
    }

    // =================================================================
    // Run phases
    // =================================================================

    pub fn run(self: *LoadGen) void {
        assert(self.stage == .seed);
        assert(self.connections_count >= 1);

        const stdout = std.io.getStdOut().writer();

        self.open_connections();

        // Phase 1: Seed — create entities so read operations have targets.
        self.requests_dispatched = 0;
        self.requests_completed = 0;
        self.requests_target = @as(u64, self.seed_count) + @as(u64, self.seed_count / 5);
        self.run_event_loop();

        assert(self.requests_completed >= self.requests_target);
        assert(self.product_count >= self.seed_count);
        assert(self.collection_count >= self.seed_count / 5);
        stdout.print("seeded {d} products, {d} collections\n\n", .{
            self.product_count,
            self.collection_count,
        }) catch unreachable;

        // Phase 2: Warmup — warm SQLite page cache, discard timing.
        self.stage = .warmup;
        self.requests_dispatched = 0;
        self.requests_completed = 0;
        self.requests_target = @max(100, self.total_requests / 100);
        self.run_event_loop();

        assert(self.requests_completed >= self.requests_target);
        self.reset_histograms();

        // Phase 3: Load — timed measurement.
        self.stage = .load;
        self.requests_dispatched = 0;
        self.requests_completed = 0;
        self.requests_target = self.total_requests;
        self.timer = std.time.Timer.start() catch unreachable;
        self.run_event_loop();

        assert(self.requests_completed >= self.requests_target);
        const duration_ns = self.timer.read();

        self.print_results(stdout, duration_ns);

        self.stage = .done;
    }

    fn run_event_loop(self: *LoadGen) void {
        assert(self.stage != .done);
        const tick_ns: u64 = 10 * std.time.ns_per_ms;
        self.dispatch_all();
        while (self.requests_completed < self.requests_target) {
            self.io.run_for_ns(tick_ns);
            self.dispatch_all();
            self.invariants();
        }
        while (self.busy_count() > 0) {
            self.io.run_for_ns(tick_ns);
        }
    }

    fn busy_count(self: *const LoadGen) u32 {
        var count: u32 = 0;
        for (self.connections[0..self.connections_count]) |*conn| {
            if (conn.state != .idle) count += 1;
        }
        return count;
    }

    fn dispatch_all(self: *LoadGen) void {
        assert(self.stage != .done);
        for (self.connections[0..self.connections_count]) |*conn| {
            if (conn.state == .idle and self.requests_completed < self.requests_target) {
                self.dispatch_request(conn);
            }
        }
    }

    fn reset_histograms(self: *LoadGen) void {
        @memset(std.mem.asBytes(&self.histograms), 0);
        @memset(&self.op_counts, 0);
    }

    // =================================================================
    // Connection management
    // =================================================================

    fn open_connections(self: *LoadGen) void {
        assert(self.connections_count >= 1);
        for (self.connections[0..self.connections_count]) |*conn| {
            assert(conn.fd == -1);
            self.connect_one(conn);
        }
    }

    fn connect_one(self: *LoadGen, conn: *Connection) void {
        assert(conn.state == .idle);
        assert(conn.load == self);

        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.port);

        const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch
            @panic("load: socket() failed");

        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch
            @panic("load: connect() failed — is the server running?");

        const current_flags = posix.fcntl(fd, posix.F.GETFL, 0) catch unreachable;
        const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
        _ = posix.fcntl(fd, posix.F.SETFL, current_flags | nonblock) catch unreachable;

        conn.fd = fd;
        conn.state = .idle;
        conn.send_len = 0;
        conn.send_pos = 0;
        conn.recv_len = 0;
        conn.completion = .{};
    }

    fn reconnect(self: *LoadGen, conn: *Connection) void {
        assert(conn.fd >= 0);
        assert(conn.load == self);
        self.reconnections += 1;
        self.io.close(conn.fd);
        conn.fd = -1;
        conn.state = .idle;
        conn.completion = .{};
        self.connect_one(conn);
    }

    fn close_connections(self: *LoadGen) void {
        for (self.connections[0..self.connections_count]) |*conn| {
            if (conn.fd >= 0) {
                self.io.close(conn.fd);
                conn.fd = -1;
                conn.state = .idle;
            }
        }
    }

    // =================================================================
    // Request dispatch
    // =================================================================

    fn dispatch_request(self: *LoadGen, conn: *Connection) void {
        assert(conn.state == .idle);
        assert(conn.fd >= 0);
        assert(conn.load == self);

        const op = self.select_operation(conn);
        conn.current_op = op;
        conn.created_id = 0;
        const send_len = self.format_request(conn, op);

        assert(send_len > 0);
        assert(send_len <= send_buf_max);

        conn.send_len = @intCast(send_len);
        conn.send_pos = 0;
        conn.recv_len = 0;
        conn.request_start_ns = self.timer.read();
        conn.state = .sending;

        self.requests_dispatched += 1;

        self.submit_send(conn);
    }

    fn submit_send(self: *LoadGen, conn: *Connection) void {
        assert(conn.state == .sending);
        assert(conn.send_pos < conn.send_len);
        assert(conn.fd >= 0);

        self.io.send(
            conn.fd,
            conn.send_buf[conn.send_pos..conn.send_len],
            &conn.completion,
            @ptrCast(conn),
            on_send,
        );
    }

    fn submit_recv(self: *LoadGen, conn: *Connection) void {
        assert(conn.state == .receiving);
        assert(conn.recv_len < recv_buf_max);
        assert(conn.fd >= 0);

        self.io.recv(
            conn.fd,
            conn.recv_buf[conn.recv_len..],
            &conn.completion,
            @ptrCast(conn),
            on_recv,
        );
    }

    /// Select the next operation for this connection. Uses the connection's
    /// own PRNG for deterministic per-connection workloads.
    fn select_operation(self: *LoadGen, conn: *Connection) LoadOp {
        if (self.stage == .seed) {
            if (self.requests_dispatched < self.seed_count) {
                return .create_product;
            }
            return .create_collection;
        }

        assert(self.product_count > 0);

        const op = conn.prng.enum_weighted(LoadOp, self.weights);

        return switch (op) {
            .get_collection => if (self.collection_count == 0) .create_collection else op,
            .get_order => if (self.order_count == 0) .create_order else op,
            .create_order, .get_product, .list_products, .list_collections,
            .list_orders, .create_product, .create_collection,
            => op,
        };
    }

    // =================================================================
    // IO callbacks
    // =================================================================

    fn on_send(ctx: *anyopaque, result: i32) void {
        const conn: *Connection = @ptrCast(@alignCast(ctx));
        const self = conn.load;
        assert(conn.state == .sending);

        if (result <= 0) {
            self.reconnect(conn);
            return;
        }

        const bytes_sent: u32 = @intCast(result);
        conn.send_pos += bytes_sent;
        assert(conn.send_pos <= conn.send_len);

        if (conn.send_pos < conn.send_len) {
            self.submit_send(conn);
            return;
        }

        conn.state = .receiving;
        conn.recv_len = 0;
        self.submit_recv(conn);
    }

    fn on_recv(ctx: *anyopaque, result: i32) void {
        const conn: *Connection = @ptrCast(@alignCast(ctx));
        const self = conn.load;
        assert(conn.state == .receiving);

        if (result <= 0) {
            self.reconnect(conn);
            return;
        }

        const bytes_recv: u32 = @intCast(result);
        conn.recv_len += bytes_recv;
        assert(conn.recv_len <= recv_buf_max);

        if (parse_response(conn.recv_buf[0..conn.recv_len]) == null) {
            if (conn.recv_len >= recv_buf_max) {
                std.debug.panic("load: conn[{d}] response exceeds recv buffer", .{conn.index});
            }
            self.submit_recv(conn);
            return;
        }

        self.on_response_complete(conn);
    }

    fn on_response_complete(self: *LoadGen, conn: *Connection) void {
        assert(conn.state == .receiving);

        const duration_ns = self.timer.read() - conn.request_start_ns;
        const duration_ms = @divTrunc(duration_ns, std.time.ns_per_ms);
        const bucket = @min(duration_ms, histogram_bucket_count - 1);

        const op_index = @intFromEnum(conn.current_op);
        self.histograms[op_index][bucket] += 1;
        self.op_counts[op_index] += 1;
        self.requests_completed += 1;

        if (conn.current_op.is_create()) {
            assert(conn.created_id != 0);
            self.track_created_id(conn.current_op, conn.created_id);
        }

        conn.state = .idle;
        if (self.requests_completed < self.requests_target) {
            self.dispatch_request(conn);
        }
    }

    fn track_created_id(self: *LoadGen, op: LoadOp, id: u128) void {
        assert(id != 0);
        switch (op) {
            .create_product => {
                if (self.product_count < id_pool_capacity) {
                    self.product_ids[self.product_count] = id;
                    self.product_count += 1;
                }
            },
            .create_collection => {
                if (self.collection_count < id_pool_capacity) {
                    self.collection_ids[self.collection_count] = id;
                    self.collection_count += 1;
                }
            },
            .create_order => {
                if (self.order_count < id_pool_capacity) {
                    self.order_ids[self.order_count] = id;
                    self.order_count += 1;
                }
            },
            else => unreachable,
        }
    }

    // =================================================================
    // HTTP request formatting
    //
    // No std.fmt in hot paths. Uses memcpy chains with hand-rolled
    // formatters (write_uuid_to_buf, format_u32). Each request uses
    // Connection: keep-alive for persistent connections.
    //
    // Created entity IDs are stored on the Connection (conn.created_id),
    // not on the LoadGen. Each connection owns its per-request state.
    // Uses the connection's own PRNG for payload generation.
    //
    // Buffer sizing is validated by the format fuzzer (90,000 random
    // inputs across all 9 operations). No hand-calculated constants.
    // =================================================================

    fn format_request(self: *LoadGen, conn: *Connection, op: LoadOp) usize {
        return switch (op) {
            .create_product => fmt_create_product(conn),
            .get_product => fmt_get_entity(conn, "/products/", self.product_ids[0..self.product_count]),
            .list_products => fmt_get(&conn.send_buf, "/products"),
            .create_collection => fmt_create_collection(conn),
            .get_collection => fmt_get_entity_or_list(conn, "/collections/", "/collections", self.collection_ids[0..self.collection_count]),
            .list_collections => fmt_get(&conn.send_buf, "/collections"),
            .create_order => self.fmt_create_order(conn),
            .get_order => fmt_get_entity_or_list(conn, "/orders/", "/orders", self.order_ids[0..self.order_count]),
            .list_orders => fmt_get(&conn.send_buf, "/orders"),
        };
    }

    fn fmt_create_product(conn: *Connection) usize {
        const id = conn.prng.int(u128) | 1;
        conn.created_id = id;

        var name_buf: [15]u8 = undefined;
        @memcpy(name_buf[0..7], "Product");
        var hex_val = conn.prng.int(u32);
        for (name_buf[7..15]) |*c| {
            c.* = "0123456789abcdef"[@intCast(hex_val & 0xf)];
            hex_val >>= 4;
        }

        const price = conn.prng.range_inclusive(u32, 100, 999_999);
        const inventory = conn.prng.range_inclusive(u32, 1, 10_000);

        var body_buf: [256]u8 = undefined;
        var pos: usize = 0;

        const pre = "{\"id\":\"";
        @memcpy(body_buf[pos..][0..pre.len], pre);
        pos += pre.len;
        stdx.write_uuid_to_buf(body_buf[pos..][0..32], id);
        pos += 32;
        const mid1 = "\",\"name\":\"";
        @memcpy(body_buf[pos..][0..mid1.len], mid1);
        pos += mid1.len;
        @memcpy(body_buf[pos..][0..name_buf.len], &name_buf);
        pos += name_buf.len;
        const mid2 = "\",\"price_cents\":";
        @memcpy(body_buf[pos..][0..mid2.len], mid2);
        pos += mid2.len;
        var u32_buf: [10]u8 = undefined;
        const price_str = stdx.format_u32(&u32_buf, price);
        @memcpy(body_buf[pos..][0..price_str.len], price_str);
        pos += price_str.len;
        const mid3 = ",\"inventory\":";
        @memcpy(body_buf[pos..][0..mid3.len], mid3);
        pos += mid3.len;
        const inv_str = stdx.format_u32(&u32_buf, inventory);
        @memcpy(body_buf[pos..][0..inv_str.len], inv_str);
        pos += inv_str.len;
        body_buf[pos] = '}';
        pos += 1;

        return fmt_post(&conn.send_buf, "/products", body_buf[0..pos]);
    }

    fn fmt_create_collection(conn: *Connection) usize {
        const id = conn.prng.int(u128) | 1;
        conn.created_id = id;

        var name_buf: [16]u8 = undefined;
        @memcpy(name_buf[0..10], "Collection");
        var hex_val = conn.prng.int(u32);
        for (name_buf[10..16]) |*c| {
            c.* = "0123456789abcdef"[@intCast(hex_val & 0xf)];
            hex_val >>= 4;
        }

        var body_buf: [128]u8 = undefined;
        var pos: usize = 0;

        const pre = "{\"id\":\"";
        @memcpy(body_buf[pos..][0..pre.len], pre);
        pos += pre.len;
        stdx.write_uuid_to_buf(body_buf[pos..][0..32], id);
        pos += 32;
        const mid = "\",\"name\":\"";
        @memcpy(body_buf[pos..][0..mid.len], mid);
        pos += mid.len;
        @memcpy(body_buf[pos..][0..name_buf.len], &name_buf);
        pos += name_buf.len;
        const suf = "\"}";
        @memcpy(body_buf[pos..][0..suf.len], suf);
        pos += suf.len;

        return fmt_post(&conn.send_buf, "/collections", body_buf[0..pos]);
    }

    fn fmt_create_order(self: *LoadGen, conn: *Connection) usize {
        const id = conn.prng.int(u128) | 1;
        conn.created_id = id;

        assert(self.product_count > 0);

        const items_count = conn.prng.range_inclusive(u8, 1, @intCast(@min(3, self.product_count)));

        var body_buf: [1024]u8 = undefined;
        var pos: usize = 0;

        const pre = "{\"id\":\"";
        @memcpy(body_buf[pos..][0..pre.len], pre);
        pos += pre.len;
        stdx.write_uuid_to_buf(body_buf[pos..][0..32], id);
        pos += 32;
        const mid = "\",\"items\":[";
        @memcpy(body_buf[pos..][0..mid.len], mid);
        pos += mid.len;

        var used_indices: [3]u32 = .{ 0, 0, 0 };

        for (0..items_count) |i| {
            if (i > 0) {
                body_buf[pos] = ',';
                pos += 1;
            }

            var prod_idx = conn.prng.int_inclusive(u32, self.product_count - 1);
            for (used_indices[0..i]) |used| {
                if (prod_idx == used) {
                    prod_idx = (prod_idx + 1) % self.product_count;
                }
            }
            used_indices[i] = prod_idx;

            const qty = conn.prng.range_inclusive(u32, 1, 5);

            const item_pre = "{\"product_id\":\"";
            @memcpy(body_buf[pos..][0..item_pre.len], item_pre);
            pos += item_pre.len;
            stdx.write_uuid_to_buf(body_buf[pos..][0..32], self.product_ids[prod_idx]);
            pos += 32;
            const item_mid = "\",\"quantity\":";
            @memcpy(body_buf[pos..][0..item_mid.len], item_mid);
            pos += item_mid.len;
            var u32_buf: [10]u8 = undefined;
            const qty_str = stdx.format_u32(&u32_buf, qty);
            @memcpy(body_buf[pos..][0..qty_str.len], qty_str);
            pos += qty_str.len;
            body_buf[pos] = '}';
            pos += 1;
        }

        const suf = "]}";
        @memcpy(body_buf[pos..][0..suf.len], suf);
        pos += suf.len;

        return fmt_post(&conn.send_buf, "/orders", body_buf[0..pos]);
    }

    fn fmt_get_entity(conn: *Connection, path_prefix: []const u8, pool: []const u128) usize {
        assert(pool.len > 0);
        const idx = conn.prng.int_inclusive(usize, pool.len - 1);
        return fmt_get_with_id(&conn.send_buf, path_prefix, pool[idx]);
    }

    fn fmt_get_entity_or_list(conn: *Connection, entity_prefix: []const u8, list_path: []const u8, pool: []const u128) usize {
        if (pool.len == 0) return fmt_get(&conn.send_buf, list_path);
        const idx = conn.prng.int_inclusive(usize, pool.len - 1);
        return fmt_get_with_id(&conn.send_buf, entity_prefix, pool[idx]);
    }

    // =================================================================
    // HTTP formatting primitives
    // =================================================================

    fn fmt_get(buf: *[send_buf_max]u8, path: []const u8) usize {
        var pos: usize = 0;
        const pre = "GET ";
        @memcpy(buf[pos..][0..pre.len], pre);
        pos += pre.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const suffix = " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
        assert(pos <= send_buf_max);
        return pos;
    }

    fn fmt_get_with_id(buf: *[send_buf_max]u8, path_prefix: []const u8, id: u128) usize {
        var pos: usize = 0;
        const pre = "GET ";
        @memcpy(buf[pos..][0..pre.len], pre);
        pos += pre.len;
        @memcpy(buf[pos..][0..path_prefix.len], path_prefix);
        pos += path_prefix.len;
        stdx.write_uuid_to_buf(buf[pos..][0..32], id);
        pos += 32;
        const suffix = " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
        assert(pos <= send_buf_max);
        return pos;
    }

    fn fmt_post(buf: *[send_buf_max]u8, path: []const u8, body: []const u8) usize {
        var pos: usize = 0;
        const pre = "POST ";
        @memcpy(buf[pos..][0..pre.len], pre);
        pos += pre.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const hdrs = " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: ";
        @memcpy(buf[pos..][0..hdrs.len], hdrs);
        pos += hdrs.len;

        var u32_buf: [10]u8 = undefined;
        const len_str = stdx.format_u32(&u32_buf, @intCast(body.len));
        @memcpy(buf[pos..][0..len_str.len], len_str);
        pos += len_str.len;

        const sep = "\r\n\r\n";
        @memcpy(buf[pos..][0..sep.len], sep);
        pos += sep.len;
        @memcpy(buf[pos..][0..body.len], body);
        pos += body.len;

        assert(pos <= send_buf_max);
        return pos;
    }

    // =================================================================
    // HTTP response parsing
    // =================================================================

    fn parse_response(data: []const u8) ?usize {
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        const headers = data[0..header_end];

        assert(headers.len >= 12);
        assert(std.mem.startsWith(u8, headers, "HTTP/1."));

        const cl_needle = "Content-Length: ";
        const cl_start = std.mem.indexOf(u8, headers, cl_needle) orelse {
            return header_end + 4;
        };
        const cl_val_start = cl_start + cl_needle.len;
        const cl_val_end = std.mem.indexOfPos(u8, headers, cl_val_start, "\r\n") orelse headers.len;
        const content_length = std.fmt.parseInt(u32, headers[cl_val_start..cl_val_end], 10) catch {
            @panic("load: invalid Content-Length");
        };

        const total_len = header_end + 4 + content_length;
        if (data.len >= total_len) return total_len;
        return null;
    }

    // =================================================================
    // Results output
    // =================================================================

    fn print_results(self: *LoadGen, writer: anytype, duration_ns: u64) void {
        assert(self.requests_completed >= self.requests_target);

        const duration_s_10 = if (duration_ns > 0) duration_ns / (std.time.ns_per_s / 10) else 1;
        const duration_s_whole = duration_s_10 / 10;
        const duration_s_frac = duration_s_10 % 10;

        var total_requests: u64 = 0;
        for (self.op_counts) |c| total_requests += c;
        assert(total_requests == self.requests_completed);

        const throughput = if (duration_ns > 0)
            total_requests * std.time.ns_per_s / duration_ns
        else
            0;

        writer.print(
            \\load:
            \\  {d} requests in {d}.{d}s
            \\  throughput = {d} req/s
            \\  reconnections = {d}
            \\
        , .{
            total_requests,
            duration_s_whole,
            duration_s_frac,
            throughput,
            self.reconnections,
        }) catch unreachable;

        writer.print("\n  {s: <24} {s: >8} {s: >8} {s: >8} {s: >8}\n", .{
            "operation", "req/s", "p50", "p99", "p100",
        }) catch unreachable;

        inline for (@typeInfo(LoadOp).@"enum".fields) |field| {
            const i = field.value;
            if (self.op_counts[i] > 0) {
                const op_throughput = if (duration_ns > 0)
                    self.op_counts[i] * std.time.ns_per_s / duration_ns
                else
                    0;
                const p50 = percentile_from_histogram(&self.histograms[i], self.op_counts[i], 50);
                const p99 = percentile_from_histogram(&self.histograms[i], self.op_counts[i], 99);
                const p100 = percentile_from_histogram(&self.histograms[i], self.op_counts[i], 100);

                writer.print("  {s: <24} {d: >8} {d: >6}ms {d: >6}ms {d: >6}ms\n", .{
                    field.name,
                    op_throughput,
                    p50,
                    p99,
                    p100,
                }) catch unreachable;
            }
        }

        var combined: [histogram_bucket_count]u64 = std.mem.zeroes([histogram_bucket_count]u64);
        for (self.histograms) |h| {
            for (&combined, h) |*c, v| c.* += v;
        }
        writer.print(
            \\
            \\  latency p1   = {d} ms
            \\  latency p50  = {d} ms
            \\  latency p99  = {d} ms
            \\  latency p100 = {d} ms{s}
            \\
        , .{
            percentile_from_histogram(&combined, total_requests, 1),
            percentile_from_histogram(&combined, total_requests, 50),
            percentile_from_histogram(&combined, total_requests, 99),
            percentile_from_histogram(&combined, total_requests, 100),
            if (percentile_from_histogram(&combined, total_requests, 100) == histogram_bucket_count - 1)
                "+ (exceeds histogram resolution)"
            else
                "",
        }) catch unreachable;

        if (self.do_analysis) {
            self.print_analysis(writer);
        }
    }

    fn print_analysis(self: *LoadGen, writer: anytype) void {
        writer.print("\nscaling analysis:\n", .{}) catch unreachable;

        var write_hist: [histogram_bucket_count]u64 = std.mem.zeroes([histogram_bucket_count]u64);
        var read_hist: [histogram_bucket_count]u64 = std.mem.zeroes([histogram_bucket_count]u64);
        var write_total: u64 = 0;
        var read_total: u64 = 0;

        inline for (@typeInfo(LoadOp).@"enum".fields) |field| {
            const op: LoadOp = @enumFromInt(field.value);
            if (op.is_create()) {
                for (&write_hist, self.histograms[field.value]) |*w, v| w.* += v;
                write_total += self.op_counts[field.value];
            } else {
                for (&read_hist, self.histograms[field.value]) |*r, v| r.* += v;
                read_total += self.op_counts[field.value];
            }
        }

        if (write_total > 0 and read_total > 0) {
            const write_p50 = percentile_from_histogram(&write_hist, write_total, 50);
            const read_p50 = percentile_from_histogram(&read_hist, read_total, 50);
            if (read_p50 > 0 and write_p50 > 2 * read_p50) {
                writer.print("  [!] write p50 ({d}ms) > 2x read p50 ({d}ms) — SQLite writes may be bottleneck\n", .{ write_p50, read_p50 }) catch unreachable;
            }
        }

        var combined: [histogram_bucket_count]u64 = std.mem.zeroes([histogram_bucket_count]u64);
        var total: u64 = 0;
        for (self.histograms) |h| {
            for (&combined, h) |*c, v| c.* += v;
        }
        for (self.op_counts) |c| total += c;

        if (total > 0) {
            const p99 = percentile_from_histogram(&combined, total, 99);
            const p100 = percentile_from_histogram(&combined, total, 100);
            if (p99 > 0 and p100 > 10 * p99) {
                writer.print("  [!] p100 ({d}ms) > 10x p99 ({d}ms) — latency spikes detected\n", .{ p100, p99 }) catch unreachable;
            }
        }

        if (self.reconnections > 0) {
            writer.print("  [!] {d} reconnections — server shedding connections\n", .{self.reconnections}) catch unreachable;
        }
    }
};

// =================================================================
// Histogram utilities
// =================================================================

fn percentile_from_histogram(
    histogram: *const [histogram_bucket_count]u64,
    total: u64,
    percentile: u64,
) u64 {
    assert(percentile >= 1);
    assert(percentile <= 100);
    assert(total > 0);

    const target = @divTrunc(total * percentile + 99, 100);
    var sum: u64 = 0;
    for (histogram, 0..) |bucket, i| {
        sum += bucket;
        if (sum >= target) return i;
    }
    return histogram_bucket_count - 1;
}

// =================================================================
// Tests
// =================================================================

// Format fuzzer — exercises all HTTP request formatters with random
// PRNG seeds and asserts buffer bounds, HTTP framing, Content-Length,
// and created_id invariants.
test "format fuzzer" {
    const iterations = 10_000;

    for (0..iterations) |seed| {
        var dummy_io: IO = undefined;
        var gen_storage: LoadGen = .{
            .io = &dummy_io,
            .timer = std.time.Timer.start() catch unreachable,
            .stage = .seed,
            .port = 0,
            .connections = undefined,
            .connections_count = 0,
            .requests_dispatched = 0,
            .requests_completed = 0,
            .requests_target = 0,
            .reconnections = 0,
            .product_ids = undefined,
            .product_count = 0,
            .collection_ids = undefined,
            .collection_count = 0,
            .order_ids = undefined,
            .order_count = 0,
            .histograms = std.mem.zeroes([load_op_count][histogram_bucket_count]u64),
            .op_counts = std.mem.zeroes([load_op_count]u64),
            .seed = seed,
            .seed_count = 0,
            .total_requests = 0,
            .do_analysis = false,
            .weights = default_weights,
        };

        // Seed ID pools with per-iteration PRNG.
        var pool_prng = PRNG.from_seed(seed);
        const n_products = pool_prng.range_inclusive(u32, 1, 16);
        for (0..n_products) |_| {
            gen_storage.product_ids[gen_storage.product_count] = pool_prng.int(u128) | 1;
            gen_storage.product_count += 1;
        }
        const n_collections = pool_prng.range_inclusive(u32, 1, 8);
        for (0..n_collections) |_| {
            gen_storage.collection_ids[gen_storage.collection_count] = pool_prng.int(u128) | 1;
            gen_storage.collection_count += 1;
        }
        const n_orders = pool_prng.range_inclusive(u32, 1, 8);
        for (0..n_orders) |_| {
            gen_storage.order_ids[gen_storage.order_count] = pool_prng.int(u128) | 1;
            gen_storage.order_count += 1;
        }

        inline for (@typeInfo(LoadOp).@"enum".fields) |field| {
            const op: LoadOp = @enumFromInt(field.value);
            var conn = Connection{ .load = &gen_storage, .prng = PRNG.from_seed(seed ^ @as(u64, field.value)) };
            const len = gen_storage.format_request(&conn, op);

            assert(len > 0);
            assert(len <= send_buf_max);

            const request = conn.send_buf[0..len];

            assert(std.mem.startsWith(u8, request, "GET ") or
                std.mem.startsWith(u8, request, "POST "));
            assert(std.mem.indexOf(u8, request, "HTTP/1.1\r\n") != null);

            const header_end = std.mem.indexOf(u8, request, "\r\n\r\n");
            assert(header_end != null);

            if (std.mem.startsWith(u8, request, "POST ")) {
                const cl_needle = "Content-Length: ";
                const cl_start = (std.mem.indexOf(u8, request, cl_needle) orelse unreachable) + cl_needle.len;
                const cl_end = std.mem.indexOfPos(u8, request, cl_start, "\r\n") orelse unreachable;
                const content_length = std.fmt.parseInt(u32, request[cl_start..cl_end], 10) catch unreachable;
                const actual_body_len = len - (header_end.? + 4);
                assert(content_length == actual_body_len);
            }

            if (op.is_create()) {
                assert(conn.created_id != 0);
            }
        }
    }
}

test "percentile_from_histogram" {
    var hist = std.mem.zeroes([histogram_bucket_count]u64);
    hist[0] = 100;
    try std.testing.expectEqual(@as(u64, 0), percentile_from_histogram(&hist, 100, 1));
    try std.testing.expectEqual(@as(u64, 0), percentile_from_histogram(&hist, 100, 50));
    try std.testing.expectEqual(@as(u64, 0), percentile_from_histogram(&hist, 100, 100));

    hist[5] = 1;
    try std.testing.expectEqual(@as(u64, 0), percentile_from_histogram(&hist, 101, 50));
    try std.testing.expectEqual(@as(u64, 0), percentile_from_histogram(&hist, 101, 99));
    try std.testing.expectEqual(@as(u64, 5), percentile_from_histogram(&hist, 101, 100));

    var hist2 = std.mem.zeroes([histogram_bucket_count]u64);
    hist2[histogram_bucket_count - 1] = 50;
    try std.testing.expectEqual(@as(u64, histogram_bucket_count - 1), percentile_from_histogram(&hist2, 50, 1));
}

test "parse_response complete" {
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expectEqual(@as(?usize, response.len), LoadGen.parse_response(response));
}

test "parse_response incomplete" {
    const partial = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhello";
    try std.testing.expectEqual(@as(?usize, null), LoadGen.parse_response(partial));
}

test "parse_response no headers yet" {
    try std.testing.expectEqual(@as(?usize, null), LoadGen.parse_response("HTTP/1.1 200"));
}

test "parse_response no content-length" {
    const response = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, response.len), LoadGen.parse_response(response));
}

test "OpsFlag parse" {
    var diag: ?[]const u8 = null;
    const result = try OpsFlag.parse_flag_value("create_product:30,list_products:50", &diag);
    try std.testing.expectEqual(@as(u32, 30), result.weights.create_product);
    try std.testing.expectEqual(@as(u32, 50), result.weights.list_products);
    try std.testing.expectEqual(@as(u32, 0), result.weights.get_product);
}

test "OpsFlag parse invalid" {
    var diag: ?[]const u8 = null;
    const result = OpsFlag.parse_flag_value("bogus:10", &diag);
    try std.testing.expectEqual(result, error.InvalidFlagValue);
    try std.testing.expect(diag != null);
}
