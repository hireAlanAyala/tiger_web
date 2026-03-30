//! Sidecar client — CALL/RESULT protocol over unix socket.
//!
//! Dumb executor model: server sends CALL frames, sidecar runs
//! functions, returns RESULT frames. QUERY sub-protocol for
//! db.query() in prefetch and render.
//!
//! State machine: call_submit → on_recv (loop) → complete/failed.
//! In Phase 2 (sync), run_to_completion drives the loop.
//! In Phase 3 (async), epoll drives on_recv.
//!
//! Server listens on unix socket, sidecar connects. Connection
//! established at startup before HTTP is accepted.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const http = @import("framework/http.zig");

const log = std.log.scoped(.sidecar);

pub const SidecarClient = struct {
    // Sized to 3 × frame_max: each round trip copies at most one
    // frame's worth of data. Three round trips = 3 × frame_max.
    //   RT1: prefetch_decl ≤ frame_max
    //   RT2: handle_writes + render_decl ≤ frame_max
    //   RT3: html ≤ frame_max
    const state_buf_max = 3 * protocol.frame_max;

    fd: std.posix.fd_t = -1,
    path: []const u8,

    // Frame buffers — heap-allocated once at init, reused per request.
    send_buf: *[protocol.frame_max]u8,
    recv_buf: *[protocol.frame_max + 4]u8,

    // Per-request state — copied into owned memory, not aliased.
    // Each phase writes to state_buf via copy_state(). The slices
    // point into state_buf, not recv_buf. Immune to call reordering.
    state_buf: *[state_buf_max]u8,
    state_pos: usize = 0,
    // Write execution state — shared between old and new protocol.
    // handler_execute sets these from the RESULT payload, then calls
    // execute_writes which reads them.
    handle_writes: []const u8 = "",
    handle_write_count: u8 = 0,

    // CALL/RESULT state machine fields — used by the new protocol.
    call_state: CallState = .idle,
    call_query_count: u32 = 0,
    result_flag: protocol.ResultFlag = .success,
    result_data: []const u8 = "",
    /// Prefetch result — stored between prefetch and handle phases.
    /// The server passes this through opaquely. Aliases state_buf.
    prefetch_result: []const u8 = "",

    comptime {
        // Memory budget: send + recv + state allocated once at startup.
        // send(256K) + recv(256K) + state(768K) ≈ 1.25MB.
        assert(protocol.frame_max + (protocol.frame_max + 4) + state_buf_max < 2 * 1024 * 1024);
        assert(@sizeOf(SidecarClient) <= 256);
    }

    pub fn init(path: []const u8) SidecarClient {
        const send = std.heap.page_allocator.create([protocol.frame_max]u8) catch
            @panic("sidecar: failed to allocate send buffer");
        const recv = std.heap.page_allocator.create([protocol.frame_max + 4]u8) catch
            @panic("sidecar: failed to allocate recv buffer");
        const state = std.heap.page_allocator.create([state_buf_max]u8) catch
            @panic("sidecar: failed to allocate state buffer");
        return .{
            .path = path,
            .send_buf = send,
            .recv_buf = recv,
            .state_buf = state,
        };
    }

    /// Copy data from recv_buf into state_buf. Returns a slice into
    /// state_buf that owns the data. Immune to recv_buf overwrites.
    pub fn copy_state(self: *SidecarClient, data: []const u8) []const u8 {
        if (data.len == 0) return "";
        const start = self.state_pos;
        assert(start + data.len <= self.state_buf.len);
        @memcpy(self.state_buf[start..][0..data.len], data);
        self.state_pos += data.len;
        return self.state_buf[start..][0..data.len];
    }

    // =================================================================
    // Connection management
    // =================================================================

    /// Listen on the unix socket path and accept one sidecar connection.
    /// Blocks until the sidecar connects. Used at startup — the server
    /// doesn't accept HTTP until the sidecar is connected.
    pub fn listen_and_accept(self: *SidecarClient) bool {
        assert(self.fd == -1);
        assert(self.path.len > 0);

        // Remove stale socket file.
        var unlink_path: [108]u8 = undefined;
        @memcpy(unlink_path[0..self.path.len], self.path);
        unlink_path[self.path.len] = 0;
        std.posix.unlinkZ(@ptrCast(unlink_path[0 .. self.path.len + 1])) catch {};

        const listen_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
            log.warn("socket: {}", .{err});
            return false;
        };

        var addr: std.posix.sockaddr.un = .{ .path = undefined };
        assert(self.path.len < addr.path.len);
        @memcpy(addr.path[0..self.path.len], self.path);
        addr.path[self.path.len] = 0;

        std.posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            log.warn("bind: {}", .{err});
            std.posix.close(listen_fd);
            return false;
        };

        std.posix.listen(listen_fd, 1) catch |err| {
            log.warn("listen: {}", .{err});
            std.posix.close(listen_fd);
            return false;
        };

        log.info("waiting for sidecar on {s}", .{self.path});

        // Blocking accept — server waits for sidecar before starting.
        const fd = std.posix.accept(listen_fd, null, null, 0) catch |err| {
            log.warn("accept: {}", .{err});
            std.posix.close(listen_fd);
            return false;
        };

        // Close the listen fd — we only accept one sidecar connection.
        std.posix.close(listen_fd);

        const timeout: std.posix.timeval = .{ .sec = 5, .usec = 0 };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            log.warn("setsockopt RCVTIMEO: {}", .{err});
            std.posix.close(fd);
            return false;
        };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            log.warn("setsockopt SNDTIMEO: {}", .{err});
            std.posix.close(fd);
            return false;
        };

        self.fd = fd;
        log.info("sidecar connected", .{});
        return true;
    }

    /// Legacy: connect TO the sidecar (old model — sidecar listens).
    /// Kept for reconnection logic until fully migrated.
    pub fn connect(self: *SidecarClient) bool {
        assert(self.fd == -1);
        assert(self.path.len > 0);

        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
            log.warn("socket: {}", .{err});
            return false;
        };

        var addr: std.posix.sockaddr.un = .{ .path = undefined };
        assert(self.path.len < addr.path.len);
        @memcpy(addr.path[0..self.path.len], self.path);
        addr.path[self.path.len] = 0;

        std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            log.warn("connect: {}", .{err});
            std.posix.close(fd);
            return false;
        };

        const timeout: std.posix.timeval = .{ .sec = 5, .usec = 0 };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            log.warn("setsockopt RCVTIMEO: {}", .{err});
            std.posix.close(fd);
            return false;
        };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            log.warn("setsockopt SNDTIMEO: {}", .{err});
            std.posix.close(fd);
            return false;
        };

        self.fd = fd;
        log.info("connected to {s}", .{self.path});
        return true;
    }

    pub fn close(self: *SidecarClient) void {
        if (self.fd != -1) {
            std.posix.close(self.fd);
            self.fd = -1;
        }
    }

    fn handle_disconnect(self: *SidecarClient) void {
        assert(self.fd != -1);
        log.warn("sidecar disconnected", .{});
        std.posix.close(self.fd);
        self.fd = -1;
        self.reset_request_state();
    }

    fn try_reconnect(self: *SidecarClient) void {
        assert(self.fd == -1);
        if (self.connect()) {
            log.info("sidecar reconnected", .{});
        }
    }

    fn reset_request_state(self: *SidecarClient) void {
        self.state_pos = 0;
        self.handle_writes = "";
        self.handle_write_count = 0;
    }

    // =================================================================
    // CALL/RESULT exchange — state machine for dumb executor protocol
    //
    // Structured as a state machine, not a blocking loop. In Phase 2
    // (sync), run_to_completion() drives all transitions in one call.
    // In Phase 3 (async), epoll drives transitions via on_recv().
    //
    // Tradeoff: the old call_exchange used comptime allow_queries to
    // eliminate the QUERY branch at compile time for no-query CALLs.
    // The state machine uses a runtime null check (query_fn == null)
    // because function pointers can't be comptime. This is the price
    // of storability — the QueryFn must be a field for async Phase 3.
    // Same tradeoff TB makes with callback context pointers.
    // The state machine is the same — only the driver changes.
    // =================================================================

    pub const CallState = enum {
        idle,          // No CALL in flight
        receiving,     // CALL sent, waiting for frames from sidecar
        complete,      // RESULT received — result_flag and result_data valid
        failed,        // Protocol error or disconnect
    };

    /// Submit a CALL frame. Transitions to .receiving.
    /// Args are copied into send_buf by build_call.
    pub fn call_submit(self: *SidecarClient, function_name: []const u8, args: []const u8) bool {
        assert(self.call_state == .idle);

        if (self.fd == -1) {
            self.try_reconnect();
            if (self.fd == -1) return false;
        }

        const call_len = protocol.build_call(
            self.send_buf,
            0, // request_id — single in-flight for sync
            function_name,
            args,
        ) orelse {
            log.warn("call: frame too large for {s}", .{function_name});
            return false;
        };

        if (!protocol.write_frame(self.fd, self.send_buf[0..call_len])) {
            self.handle_disconnect();
            return false;
        }

        self.call_state = .receiving;
        self.call_query_count = 0;
        return true;
    }

    /// Query dispatch function type. The context is an opaque pointer
    /// to the storage ReadView (or whatever provides query_raw).
    /// Same pattern as TB's IO callbacks — context + operation.
    pub const QueryFn = *const fn (
        context: *anyopaque,
        sql: []const u8,
        params_buf: []const u8,
        param_count: u8,
        mode: protocol.QueryMode,
        out_buf: []u8,
    ) ?[]const u8;

    /// Process one received frame. Called by the recv loop (sync) or
    /// epoll handler (async). Returns the new state.
    ///
    /// On .query: executes SQL via query_fn(query_ctx), sends QUERY_RESULT.
    /// On .result: stores result, transitions to .complete.
    /// On error: transitions to .failed.
    pub fn on_recv(
        self: *SidecarClient,
        query_fn: ?QueryFn,
        query_ctx: ?*anyopaque,
        comptime queries_max: u32,
    ) CallState {
        assert(self.call_state == .receiving);

        const frame = protocol.read_frame(self.fd, self.recv_buf) orelse {
            self.handle_disconnect();
            self.call_state = .failed;
            return .failed;
        };

        const parsed = protocol.parse_sidecar_frame(frame) orelse {
            log.warn("call: invalid frame from sidecar", .{});
            self.handle_disconnect();
            self.call_state = .failed;
            return .failed;
        };

        switch (parsed.tag) {
            .result => {
                const result = protocol.parse_result_payload(parsed.payload) orelse {
                    log.warn("call: invalid RESULT payload", .{});
                    self.handle_disconnect();
                    self.call_state = .failed;
                    return .failed;
                };
                self.result_flag = result.flag;
                self.result_data = result.data;
                self.call_state = .complete;
                return .complete;
            },
            .query => {
                if (query_fn == null) {
                    log.warn("call: QUERY received during no-query CALL", .{});
                    self.handle_disconnect();
                    self.call_state = .failed;
                    return .failed;
                }

                if (self.call_query_count >= queries_max) {
                    log.warn("call: exceeded max queries ({d})", .{queries_max});
                    self.handle_disconnect();
                    self.call_state = .failed;
                    return .failed;
                }
                self.call_query_count += 1;

                const query = protocol.parse_query_payload(parsed.payload) orelse {
                    log.warn("call: invalid QUERY payload", .{});
                    self.handle_disconnect();
                    self.call_state = .failed;
                    return .failed;
                };

                // Execute SQL via the caller's query function.
                // Row set written directly into send_buf after the
                // 7-byte QUERY_RESULT header (tag + request_id + query_id).
                const row_set = query_fn.?(
                    query_ctx.?,
                    query.sql,
                    query.params_buf,
                    query.param_count,
                    query.mode,
                    self.send_buf[7..],
                ) orelse blk: {
                    break :blk @as([]const u8, "");
                };

                // Send QUERY_RESULT — echo query_id for Promise.all() matching.
                self.send_buf[0] = @intFromEnum(protocol.CallTag.query_result);
                std.mem.writeInt(u32, self.send_buf[1..5], parsed.request_id, .big);
                std.mem.writeInt(u16, self.send_buf[5..7], query.query_id, .big);
                const qr_total = 7 + row_set.len;

                if (!protocol.write_frame(self.fd, self.send_buf[0..qr_total])) {
                    self.handle_disconnect();
                    self.call_state = .failed;
                    return .failed;
                }

                // Stay in .receiving — more frames expected.
                return .receiving;
            },
            else => unreachable,
        }
    }

    /// Drive the state machine to completion. Blocking — used in Phase 2.
    /// In Phase 3, this is replaced by epoll-driven on_recv() calls.
    pub fn run_to_completion(
        self: *SidecarClient,
        query_fn: ?QueryFn,
        query_ctx: ?*anyopaque,
        comptime queries_max: u32,
    ) bool {
        assert(self.call_state == .receiving);
        while (self.call_state == .receiving) {
            _ = self.on_recv(query_fn, query_ctx, queries_max);
        }
        return self.call_state == .complete;
    }

    /// Reset call state between requests.
    pub fn reset_call_state(self: *SidecarClient) void {
        self.call_state = .idle;
        self.call_query_count = 0;
        self.result_flag = .success;
        self.result_data = "";
    }

    // =================================================================
    // Execute writes
    // =================================================================

    /// Execute handle's write queue against storage.
    /// Called inside the server's transaction boundary.
    pub fn execute_writes(self: *SidecarClient, storage: anytype) bool {
        const data = self.handle_writes;
        if (self.handle_write_count == 0) return true;

        var dpos: usize = 0;
        for (0..self.handle_write_count) |_| {
            // sql: [u16 BE sql_len][sql_bytes]
            if (dpos + 2 > data.len) return false;
            const sql_len = std.mem.readInt(u16, data[dpos..][0..2], .big);
            dpos += 2;
            if (dpos + sql_len > data.len) return false;
            const sql = data[dpos..][0..sql_len];
            dpos += sql_len;

            // params: [u8 param_count][params...]
            if (dpos >= data.len) return false;
            const param_count = data[dpos];
            dpos += 1;
            const params_start = dpos;
            dpos = skip_params(data, dpos, param_count) orelse return false;

            if (!storage.execute_raw(sql, data[params_start..dpos], param_count)) {
                return false;
            }
        }
        return true;
    }
    // =================================================================
    // Binary format helpers — shared parsing for declarations/params
    // =================================================================

    /// Skip past one param list in a binary buffer.
    /// Returns new position, or null if malformed.
    pub fn skip_params(data: []const u8, start: usize, param_count: u8) ?usize {
        var pos = start;
        for (0..param_count) |_| {
            if (pos >= data.len) return null;
            const tag = std.meta.intToEnum(protocol.TypeTag, data[pos]) catch return null;
            pos += 1;
            switch (tag) {
                .integer, .float => {
                    if (pos + 8 > data.len) return null;
                    pos += 8;
                },
                .text, .blob => {
                    if (pos + 2 > data.len) return null;
                    const vlen = std.mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    if (pos + vlen > data.len) return null;
                    pos += vlen;
                },
                .null => {},
            }
        }
        return pos;
    }

};
