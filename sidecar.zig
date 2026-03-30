//! Unix socket client for the sidecar binary protocol.
//!
//! Three round trips per HTTP request:
//!   RT1: route_request → route_prefetch_response
//!   RT2: prefetch_results → handle_render_response
//!   RT3: render_results → html_response
//!
//! The sidecar pipeline (app.sidecar_commit_and_encode) orchestrates
//! calls to this client. The SM is NOT involved — the sidecar has its
//! own pipeline with the same building blocks (transactions, auth, WAL).
//!
//! Methods must be called in order:
//!   translate → execute_prefetch → send_prefetch_recv_handle →
//!   execute_writes → execute_render
//! Per-request state is copied into state_buf (owned memory). Slices
//! do not alias recv_buf — immune to call reordering.
//!
//! Sidecar failure at any point: close connection, return error to HTTP
//! client, reconnect lazily on next request. No mid-exchange retry.
//! No retry because: writes may have committed, re-running the handler
//! against post-commit state produces different results. The operation
//! either completed or it didn't. The client retries (TB pattern).

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
    prefetch_decl: []const u8 = "",
    render_decl: []const u8 = "",
    handle_status: message.Status = .ok,
    handle_writes: []const u8 = "",
    handle_write_count: u8 = 0,
    html: []const u8 = "",
    /// Prefetch result size — stored between handler_prefetch and
    /// handler_execute so the pipeline can pass it across phases.
    stored_prefetch_len: usize = 0,

    comptime {
        // Memory budget: send + recv + state allocated once at startup.
        // send(256K) + recv(256K) + state(768K) ≈ 1.25MB.
        assert(protocol.frame_max + (protocol.frame_max + 4) + state_buf_max < 2 * 1024 * 1024);
        assert(@sizeOf(SidecarClient) <= 128);
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
    fn copy_state(self: *SidecarClient, data: []const u8) []const u8 {
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
        self.prefetch_decl = "";
        self.render_decl = "";
        self.handle_status = .ok;
        self.handle_writes = "";
        self.handle_write_count = 0;
        self.html = "";
    }

    // =================================================================
    // CALL/RESULT exchange — dumb executor protocol
    //
    // Send a CALL frame, handle QUERY sub-protocol, return RESULT.
    // This is the universal primitive for the new protocol.
    // =================================================================

    /// Result of a CALL/RESULT exchange.
    pub const ExchangeResult = struct {
        flag: protocol.ResultFlag,
        /// RESULT payload after the flag byte. Aliases recv_buf —
        /// consume before the next call_exchange.
        data: []const u8,
    };

    /// Send a CALL, handle QUERY sub-protocol, return RESULT.
    ///
    /// When `allow_queries` is true, QUERY frames from the sidecar are
    /// dispatched to storage (db.query). When false, QUERY frames are
    /// a protocol violation — disconnect.
    ///
    /// `queries_max` bounds the QUERY loop. If the sidecar exceeds the
    /// limit, the exchange fails.
    pub fn call_exchange(
        self: *SidecarClient,
        function_name: []const u8,
        args: []const u8,
        storage: anytype,
        comptime allow_queries: bool,
        comptime queries_max: u32,
    ) ?ExchangeResult {
        if (self.fd == -1) {
            self.try_reconnect();
            if (self.fd == -1) return null;
        }

        // Build and send CALL frame.
        const call_len = protocol.build_call(self.send_buf, 0, function_name, args) orelse {
            log.warn("call: frame too large for {s}", .{function_name});
            return null;
        };
        if (!protocol.write_frame(self.fd, self.send_buf[0..call_len])) {
            self.handle_disconnect();
            return null;
        }

        // Recv loop: handle QUERY frames until RESULT arrives.
        var query_count: u32 = 0;
        while (true) {
            const frame = protocol.read_frame(self.fd, self.recv_buf) orelse {
                self.handle_disconnect();
                return null;
            };

            const parsed = protocol.parse_sidecar_frame(frame) orelse {
                log.warn("call: invalid frame from sidecar", .{});
                self.handle_disconnect();
                return null;
            };

            switch (parsed.tag) {
                .result => {
                    const result = protocol.parse_result_payload(parsed.payload) orelse {
                        log.warn("call: invalid RESULT payload", .{});
                        self.handle_disconnect();
                        return null;
                    };
                    return .{
                        .flag = result.flag,
                        .data = result.data,
                    };
                },
                .query => {
                    if (!allow_queries) {
                        log.warn("call: QUERY received during no-query CALL {s}", .{function_name});
                        self.handle_disconnect();
                        return null;
                    }

                    if (query_count >= queries_max) {
                        log.warn("call: exceeded max queries ({d}) for {s}", .{ queries_max, function_name });
                        self.handle_disconnect();
                        return null;
                    }
                    query_count += 1;

                    const query = protocol.parse_query_payload(parsed.payload) orelse {
                        log.warn("call: invalid QUERY payload", .{});
                        self.handle_disconnect();
                        return null;
                    };

                    // Execute SQL via storage ReadView, write row set
                    // directly into send_buf after the 5-byte header.
                    const row_set = storage.query_raw(
                        query.sql,
                        query.params_buf,
                        query.param_count,
                        query.mode,
                        self.send_buf[5..],
                    ) orelse blk: {
                        // Query failed — send empty QUERY_RESULT.
                        break :blk @as([]const u8, "");
                    };

                    // Build QUERY_RESULT header in the first 5 bytes.
                    self.send_buf[0] = @intFromEnum(protocol.CallTag.query_result);
                    std.mem.writeInt(u32, self.send_buf[1..5], parsed.request_id, .big);
                    const qr_total = 5 + row_set.len;

                    if (!protocol.write_frame(self.fd, self.send_buf[0..qr_total])) {
                        self.handle_disconnect();
                        return null;
                    }
                },
                else => unreachable,
            }
        }
    }

    // =================================================================
    // RT1: Route (legacy 3-RT protocol)
    // =================================================================

    /// Send route_request, receive route_prefetch_response.
    /// Stores prefetch declarations for execute_prefetch.
    pub fn translate(
        self: *SidecarClient,
        method_val: http.Method,
        path: []const u8,
        body: []const u8,
    ) ?message.Message {
        if (self.fd == -1) self.try_reconnect();
        if (self.fd == -1) return null;
        self.reset_request_state();

        // Build route_request: [tag][method][u16 path_len][path][u16 body_len][body]
        var pos: usize = 0;
        const buf = self.send_buf;

        buf[pos] = @intFromEnum(protocol.MessageTag.route_request);
        pos += 1;
        buf[pos] = @intFromEnum(method_val);
        pos += 1;
        if (path.len > 0xFFFF) return null;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(path.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        if (body.len > 0xFFFF) return null;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(body.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..body.len], body);
        pos += body.len;

        if (!protocol.write_frame(self.fd, buf[0..pos])) {
            self.handle_disconnect();
            return null;
        }

        // Receive: [tag][found][operation][u128 id BE][prefetch_declarations...]
        const resp = protocol.read_frame(self.fd, self.recv_buf) orelse {
            self.handle_disconnect();
            return null;
        };

        if (resp.len < 3) { self.handle_disconnect(); return null; }
        if (resp[0] != @intFromEnum(protocol.MessageTag.route_prefetch_response)) {
            log.err("translate: unexpected tag {d}", .{resp[0]});
            self.handle_disconnect();
            return null;
        }
        if (resp[1] == 0) return null; // not found

        const operation = std.meta.intToEnum(message.Operation, resp[2]) catch {
            log.err("translate: unknown operation {d}", .{resp[2]});
            self.handle_disconnect();
            return null;
        };

        if (resp.len < 19) { self.handle_disconnect(); return null; }
        const id = std.mem.readInt(u128, resp[3..19], .big);
        self.prefetch_decl = self.copy_state(resp[19..]);

        var msg = std.mem.zeroes(message.Message);
        msg.operation = operation;
        msg.id = id;
        return msg;
    }

    // =================================================================
    // RT2 send: Prefetch — execute declared SQL, build results frame
    // =================================================================

    /// Execute prefetch SQL declarations from RT1. Write row sets into
    /// send_buf. Returns frame length, or null on error.
    /// Consumes prefetch_decl (aliases recv_buf from RT1).
    pub fn execute_prefetch(self: *SidecarClient, storage: anytype) ?usize {
        const decl = self.prefetch_decl;
        var buf = self.send_buf;
        var pos: usize = 0;

        buf[pos] = @intFromEnum(protocol.MessageTag.prefetch_results);
        pos += 1;

        if (decl.len == 0) return pos;

        var iter = DeclIterator.init(decl) orelse return null;
        while (iter.next()) |entry| {
            const result = storage.query_raw(entry.sql, entry.params, entry.param_count, entry.mode, buf[pos..]);
            if (result) |row_data| {
                pos += row_data.len;
            } else {
                // Prefetch query failed — fail the entire request.
                // A query failure means the SQL is bad (scanner bug) or
                // the schema changed. Silent empty results would cause
                // the handler to make wrong decisions.
                return null;
            }
        }
        if (!iter.valid) return null;

        return pos;
    }

    // =================================================================
    // RT2 recv: Handle — send prefetch results, receive handle response
    // =================================================================

    /// Send prefetch results, receive handle_render_response.
    /// Stores status, writes, render declarations.
    pub fn send_prefetch_recv_handle(self: *SidecarClient, prefetch_len: usize) ?message.Status {
        if (!protocol.write_frame(self.fd, self.send_buf[0..prefetch_len])) {
            self.handle_disconnect();
            return null;
        }

        // Receive: [tag][status][u8 write_count][writes...][render_declarations...]
        const resp = protocol.read_frame(self.fd, self.recv_buf) orelse {
            self.handle_disconnect();
            return null;
        };

        if (resp.len < 3) { self.handle_disconnect(); return null; }
        if (resp[0] != @intFromEnum(protocol.MessageTag.handle_render_response)) {
            log.err("handle: unexpected tag {d}", .{resp[0]});
            self.handle_disconnect();
            return null;
        }

        const status = std.meta.intToEnum(message.Status, resp[1]) catch {
            log.err("handle: unknown status {d}", .{resp[1]});
            self.handle_disconnect();
            return null;
        };
        self.handle_status = status;

        const write_count = resp[2];
        if (write_count > protocol.writes_max) {
            log.err("handle: write count {d} exceeds max {d}", .{ write_count, protocol.writes_max });
            self.handle_disconnect();
            return null;
        }
        self.handle_write_count = write_count;

        // Scan past write entries to find render declarations.
        var dpos: usize = 3;
        const writes_start = dpos;
        for (0..write_count) |_| {
            dpos = skip_write_entry(resp, dpos) orelse {
                self.handle_disconnect();
                return null;
            };
        }

        self.handle_writes = self.copy_state(resp[writes_start..dpos]);
        self.render_decl = self.copy_state(resp[dpos..]);
        return status;
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
    // RT3: Render — execute render SQL, send results, receive HTML
    // =================================================================

    /// Execute render SQL, send results, receive HTML.
    /// Returns HTML slice (aliases recv_buf).
    pub fn execute_render(self: *SidecarClient, storage: anytype) ?[]const u8 {
        var buf = self.send_buf;
        var pos: usize = 0;

        buf[pos] = @intFromEnum(protocol.MessageTag.render_results);
        pos += 1;

        const decl = self.render_decl;
        if (decl.len > 0) {
            var iter = DeclIterator.init(decl) orelse return null;
            while (iter.next()) |entry| {
                const result = storage.query_raw(entry.sql, entry.params, entry.param_count, entry.mode, buf[pos..]);
                if (result) |row_data| {
                    pos += row_data.len;
                } else {
                    // Render query failed — write empty row set.
                    // Unlike prefetch, render failure is non-fatal: the
                    // handler renders an error or fallback for missing data.
                    if (pos + 6 > buf.len) return null;
                    std.mem.writeInt(u16, buf[pos..][0..2], 0, .big);
                    pos += 2;
                    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
                    pos += 4;
                }
            }
            if (!iter.valid) return null;
        }

        if (!protocol.write_frame(self.fd, buf[0..pos])) {
            self.handle_disconnect();
            return null;
        }

        // Receive: [tag][html_bytes...]
        const resp = protocol.read_frame(self.fd, self.recv_buf) orelse {
            self.handle_disconnect();
            return null;
        };

        if (resp.len < 1) { self.handle_disconnect(); return null; }
        if (resp[0] != @intFromEnum(protocol.MessageTag.html_response)) {
            log.err("render: unexpected tag {d}", .{resp[0]});
            self.handle_disconnect();
            return null;
        }

        self.html = self.copy_state(resp[1..]);
        return self.html;
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

    /// Skip past one write entry: [u16 sql_len][sql][u8 param_count][params...]
    fn skip_write_entry(data: []const u8, start: usize) ?usize {
        var pos = start;
        if (pos + 2 > data.len) return null;
        const sql_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
        if (pos + sql_len > data.len) return null;
        pos += sql_len;
        if (pos >= data.len) return null;
        const param_count = data[pos];
        pos += 1;
        return skip_params(data, pos, param_count);
    }

    /// Iterator over SQL declarations (prefetch or render).
    /// Format: [u8 query_count][queries: { key, sql, mode, params }]
    pub const DeclIterator = struct {
        data: []const u8,
        pos: usize,
        remaining: u8,
        valid: bool,

        const Entry = struct {
            sql: []const u8,
            params: []const u8,
            param_count: u8,
            mode: protocol.QueryMode,
        };

        pub fn init(data: []const u8) ?DeclIterator {
            if (data.len == 0) return null;
            return .{
                .data = data,
                .pos = 1,
                .remaining = data[0],
                .valid = true,
            };
        }

        pub fn next(self: *DeclIterator) ?Entry {
            if (self.remaining == 0) return null;
            self.remaining -= 1;

            const d = self.data;
            var p = self.pos;

            // key: [u8 key_len][key_bytes] — skip, framework doesn't need it
            if (p >= d.len) { self.valid = false; return null; }
            const key_len = d[p];
            p += 1;
            if (p + key_len > d.len) { self.valid = false; return null; }
            p += key_len;

            // sql: [u16 BE sql_len][sql_bytes]
            if (p + 2 > d.len) { self.valid = false; return null; }
            const sql_len = std.mem.readInt(u16, d[p..][0..2], .big);
            p += 2;
            if (p + sql_len > d.len) { self.valid = false; return null; }
            const sql = d[p..][0..sql_len];
            p += sql_len;

            // mode: [u8]
            if (p >= d.len) { self.valid = false; return null; }
            const mode = std.meta.intToEnum(protocol.QueryMode, d[p]) catch {
                self.valid = false;
                return null;
            };
            p += 1;

            // params: [u8 param_count][params...]
            if (p >= d.len) { self.valid = false; return null; }
            const param_count = d[p];
            p += 1;
            const params_start = p;
            p = skip_params(d, p, param_count) orelse {
                self.valid = false;
                return null;
            };

            self.pos = p;
            return .{
                .sql = sql,
                .params = d[params_start..p],
                .param_count = param_count,
                .mode = mode,
            };
        }
    };
};
