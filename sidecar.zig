//! Unix socket client for the sidecar binary protocol.
//!
//! Three round trips per HTTP request:
//!   RT1: route_request → route_prefetch_response
//!   RT2: prefetch_results → handle_render_response
//!   RT3: render_results → html_response
//!
//! The client stores per-request state between SM calls (single-threaded,
//! one request at a time). The SM calls translate → prefetch → execute →
//! render. Each call advances the protocol exchange.
//!
//! Sidecar failure at any point: close connection, return error to HTTP
//! client, reconnect lazily on next request. No mid-exchange retry.
//! See docs/plans/sidecar-protocol.md.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const http = @import("tiger_framework").http;

const log = std.log.scoped(.sidecar);

pub const SidecarClient = struct {
    fd: std.posix.fd_t = -1,
    path: []const u8,

    // Frame buffers — heap-allocated once at init, reused per request.
    // Single-threaded: one request at a time.
    send_buf: *[protocol.frame_max]u8,
    recv_buf: *[protocol.frame_max + 4]u8,

    // Per-request state — stored between SM calls.
    // Set by translate (RT1), consumed by prefetch/execute/render.
    // Reset on disconnect or at the start of each translate.
    prefetch_decl: []const u8 = "", // raw binary: prefetch SQL declarations from RT1
    render_decl: []const u8 = "", // raw binary: render SQL declarations from RT2
    handle_status: message.Status = .ok,
    handle_writes: []const u8 = "", // raw binary: write queue from RT2
    html: []const u8 = "", // raw binary: HTML from RT3

    comptime {
        assert(2 * (protocol.frame_max + 4) < 1024 * 1024);
        assert(@sizeOf(SidecarClient) <= 128);
    }

    pub fn init(path: []const u8) SidecarClient {
        const send = std.heap.page_allocator.create([protocol.frame_max]u8) catch
            @panic("sidecar: failed to allocate send buffer");
        const recv = std.heap.page_allocator.create([protocol.frame_max + 4]u8) catch
            @panic("sidecar: failed to allocate recv buffer");
        return .{
            .path = path,
            .send_buf = send,
            .recv_buf = recv,
        };
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
        self.prefetch_decl = "";
        self.render_decl = "";
        self.handle_status = .ok;
        self.handle_writes = "";
        self.html = "";
    }

    // =================================================================
    // RT1: Route — translate HTTP request to operation + prefetch SQL
    // =================================================================

    /// Send route_request, receive route_prefetch_response.
    /// Returns the operation + id as a Message, or null if unmapped.
    /// Stores prefetch declarations for the subsequent prefetch call.
    pub fn translate(
        self: *SidecarClient,
        method_val: http.Method,
        path: []const u8,
        body: []const u8,
    ) ?message.Message {
        if (self.fd == -1) self.try_reconnect();
        if (self.fd == -1) return null;
        self.reset_request_state();

        // Build route_request frame.
        // [u8 tag][u8 method][u16 BE path_len][path bytes][u16 BE body_len][body bytes]
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

        // Receive route_prefetch_response.
        // [u8 tag][u8 found][u8 operation][u128 id (16 bytes BE)][prefetch_declarations...]
        const resp = protocol.read_frame(self.fd, self.recv_buf) orelse {
            self.handle_disconnect();
            return null;
        };

        if (resp.len < 3) {
            self.handle_disconnect();
            return null;
        }

        // Validate tag.
        if (resp[0] != @intFromEnum(protocol.MessageTag.route_prefetch_response)) {
            log.err("translate: unexpected tag {d}", .{resp[0]});
            self.handle_disconnect();
            return null;
        }

        // Found flag.
        if (resp[1] == 0) return null; // not found — no route matched

        // Operation.
        const op_byte = resp[2];
        const operation = std.meta.intToEnum(message.Operation, op_byte) catch {
            log.err("translate: unknown operation {d}", .{op_byte});
            self.handle_disconnect();
            return null;
        };

        // ID (u128 big-endian, 16 bytes).
        if (resp.len < 19) {
            self.handle_disconnect();
            return null;
        }
        const id = std.mem.readInt(u128, resp[3..19], .big);

        // Store prefetch declarations (rest of the frame).
        self.prefetch_decl = resp[19..];

        var msg = std.mem.zeroes(message.Message);
        msg.operation = operation;
        msg.id = id;
        return msg;
    }

    // =================================================================
    // RT2 send: Prefetch — execute declared SQL, send results
    // =================================================================

    /// Execute the prefetch SQL declarations stored from RT1.
    /// Write the row set results into send_buf for RT2.
    /// Returns the number of bytes of prefetch results, or null on error.
    pub fn execute_prefetch(self: *SidecarClient, storage: anytype) ?usize {
        const decl = self.prefetch_decl;
        var buf = self.send_buf;

        // Frame payload: [u8 tag][row_set_0][row_set_1]...
        var pos: usize = 0;
        buf[pos] = @intFromEnum(protocol.MessageTag.prefetch_results);
        pos += 1;

        // Parse declarations: [u8 query_count][queries...]
        if (decl.len == 0) return pos; // no prefetch queries
        const query_count = decl[0];
        var dpos: usize = 1;

        for (0..query_count) |_| {
            // key: [u8 key_len][key_bytes]
            if (dpos >= decl.len) return null;
            const key_len = decl[dpos];
            dpos += 1;
            if (dpos + key_len > decl.len) return null;
            // Key not needed by the framework — the sidecar uses it to
            // build ctx.prefetched. We just execute the SQL and send rows.
            dpos += key_len;

            // sql: [u16 BE sql_len][sql_bytes]
            if (dpos + 2 > decl.len) return null;
            const sql_len = std.mem.readInt(u16, decl[dpos..][0..2], .big);
            dpos += 2;
            if (dpos + sql_len > decl.len) return null;
            const sql = decl[dpos..][0..sql_len];
            dpos += sql_len;

            // mode: [u8]
            if (dpos >= decl.len) return null;
            const mode_byte = decl[dpos];
            dpos += 1;
            const mode = std.meta.intToEnum(protocol.QueryMode, mode_byte) catch return null;

            // params: [u8 param_count][params...]
            if (dpos >= decl.len) return null;
            const param_count = decl[dpos];
            dpos += 1;

            // Find the end of params by scanning type tags + values.
            const params_start = dpos;
            var pi: usize = 0;
            while (pi < param_count) : (pi += 1) {
                if (dpos >= decl.len) return null;
                const tag_byte = decl[dpos];
                dpos += 1;
                const tag = std.meta.intToEnum(protocol.TypeTag, tag_byte) catch return null;
                switch (tag) {
                    .integer, .float => dpos += 8,
                    .text, .blob => {
                        if (dpos + 2 > decl.len) return null;
                        const vlen = std.mem.readInt(u16, decl[dpos..][0..2], .big);
                        dpos += 2 + vlen;
                    },
                    .null => {},
                }
            }
            const params_buf = decl[params_start..dpos];

            // Execute the query via storage.query_raw.
            const result = storage.query_raw(sql, params_buf, param_count, mode, buf[pos..]);
            if (result) |row_data| {
                pos += row_data.len;
            } else {
                // Query failed — write an empty row set (0 columns, 0 rows).
                if (pos + 6 > buf.len) return null;
                std.mem.writeInt(u16, buf[pos..][0..2], 0, .big); // 0 columns
                pos += 2;
                std.mem.writeInt(u32, buf[pos..][0..4], 0, .big); // 0 rows
                pos += 4;
            }
        }

        return pos;
    }

    // =================================================================
    // RT2 recv: Handle — send prefetch results, receive status + writes
    // =================================================================

    /// Send prefetch results frame (RT2 send), receive handle_render_response
    /// (RT2 recv). Stores status, writes, and render declarations.
    /// Returns the status, or null on error.
    pub fn send_prefetch_recv_handle(self: *SidecarClient, prefetch_len: usize) ?message.Status {
        // Send prefetch results.
        if (!protocol.write_frame(self.fd, self.send_buf[0..prefetch_len])) {
            self.handle_disconnect();
            return null;
        }

        // Receive handle_render_response.
        // [u8 tag][u8 status][writes...][render_declarations...]
        const resp = protocol.read_frame(self.fd, self.recv_buf) orelse {
            self.handle_disconnect();
            return null;
        };

        if (resp.len < 2) {
            self.handle_disconnect();
            return null;
        }

        if (resp[0] != @intFromEnum(protocol.MessageTag.handle_render_response)) {
            log.err("handle: unexpected tag {d}", .{resp[0]});
            self.handle_disconnect();
            return null;
        }

        // Status.
        const status = std.meta.intToEnum(message.Status, resp[1]) catch {
            log.err("handle: unknown status {d}", .{resp[1]});
            self.handle_disconnect();
            return null;
        };
        self.handle_status = status;

        // Parse writes and render declarations from the rest of the frame.
        // [u8 write_count][writes...][render_declarations...]
        if (resp.len < 3) {
            self.handle_disconnect();
            return null;
        }

        var dpos: usize = 2;
        const write_count = resp[dpos];
        dpos += 1;

        // Scan past write entries to find where render declarations start.
        const writes_start = dpos;
        for (0..write_count) |_| {
            // sql: [u16 BE sql_len][sql_bytes]
            if (dpos + 2 > resp.len) {
                self.handle_disconnect();
                return null;
            }
            const sql_len = std.mem.readInt(u16, resp[dpos..][0..2], .big);
            dpos += 2 + sql_len;

            // params: [u8 param_count][params...]
            if (dpos >= resp.len) {
                self.handle_disconnect();
                return null;
            }
            const param_count = resp[dpos];
            dpos += 1;
            for (0..param_count) |_| {
                if (dpos >= resp.len) {
                    self.handle_disconnect();
                    return null;
                }
                const tag = std.meta.intToEnum(protocol.TypeTag, resp[dpos]) catch {
                    self.handle_disconnect();
                    return null;
                };
                dpos += 1;
                switch (tag) {
                    .integer, .float => dpos += 8,
                    .text, .blob => {
                        if (dpos + 2 > resp.len) {
                            self.handle_disconnect();
                            return null;
                        }
                        const vlen = std.mem.readInt(u16, resp[dpos..][0..2], .big);
                        dpos += 2 + vlen;
                    },
                    .null => {},
                }
            }
        }

        self.handle_writes = resp[writes_start..dpos];
        self.render_decl = resp[dpos..];

        return status;
    }

    // =================================================================
    // Execute writes from handle result
    // =================================================================

    /// Execute the write queue from handle_render_response against storage.
    /// Called by the framework inside the transaction boundary.
    pub fn execute_writes(self: *SidecarClient, storage: anytype) bool {
        const data = self.handle_writes;
        if (data.len == 0) return true;

        var dpos: usize = 0;

        // The write_count was already parsed in send_prefetch_recv_handle.
        // handle_writes starts after the write_count byte — it's the raw
        // write entries. We need to re-read the count from the original
        // response. Actually, handle_writes includes the entries but not
        // the count. Let me re-parse.
        //
        // Actually, looking at how we set handle_writes above:
        // writes_start is after write_count, so handle_writes doesn't
        // include the count. We need to store it separately.
        // For now, scan the entries — each starts with u16 sql_len.
        while (dpos < data.len) {
            // sql: [u16 BE sql_len][sql_bytes]
            if (dpos + 2 > data.len) break;
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

            // Scan past params to find the end.
            for (0..param_count) |_| {
                if (dpos >= data.len) return false;
                const tag = std.meta.intToEnum(protocol.TypeTag, data[dpos]) catch return false;
                dpos += 1;
                switch (tag) {
                    .integer, .float => dpos += 8,
                    .text, .blob => {
                        if (dpos + 2 > data.len) return false;
                        const vlen = std.mem.readInt(u16, data[dpos..][0..2], .big);
                        dpos += 2 + vlen;
                    },
                    .null => {},
                }
            }

            if (!storage.execute_raw(sql, data[params_start..dpos], param_count)) {
                return false;
            }
        }
        return true;
    }

    // =================================================================
    // RT3: Render — execute render SQL, send results, receive HTML
    // =================================================================

    /// Execute render SQL declarations, send results, receive HTML.
    /// Returns the HTML slice (aliases recv_buf), or null on error.
    pub fn execute_render(self: *SidecarClient, storage: anytype) ?[]const u8 {
        var buf = self.send_buf;

        // Build render_results frame.
        var pos: usize = 0;
        buf[pos] = @intFromEnum(protocol.MessageTag.render_results);
        pos += 1;

        // Execute render SQL declarations (same format as prefetch).
        const decl = self.render_decl;
        if (decl.len > 0) {
            const query_count = decl[0];
            var dpos: usize = 1;

            for (0..query_count) |_| {
                // key
                if (dpos >= decl.len) return null;
                const key_len = decl[dpos];
                dpos += 1 + key_len;

                // sql
                if (dpos + 2 > decl.len) return null;
                const sql_len = std.mem.readInt(u16, decl[dpos..][0..2], .big);
                dpos += 2;
                const sql = decl[dpos..][0..sql_len];
                dpos += sql_len;

                // mode
                if (dpos >= decl.len) return null;
                const mode_byte = decl[dpos];
                dpos += 1;
                const mode = std.meta.intToEnum(protocol.QueryMode, mode_byte) catch return null;

                // params
                if (dpos >= decl.len) return null;
                const param_count = decl[dpos];
                dpos += 1;
                const params_start = dpos;
                var pi: usize = 0;
                while (pi < param_count) : (pi += 1) {
                    if (dpos >= decl.len) return null;
                    const tag = std.meta.intToEnum(protocol.TypeTag, decl[dpos]) catch return null;
                    dpos += 1;
                    switch (tag) {
                        .integer, .float => dpos += 8,
                        .text, .blob => {
                            if (dpos + 2 > decl.len) return null;
                            const vlen = std.mem.readInt(u16, decl[dpos..][0..2], .big);
                            dpos += 2 + vlen;
                        },
                        .null => {},
                    }
                }

                const result = storage.query_raw(sql, decl[params_start..dpos], param_count, mode, buf[pos..]);
                if (result) |row_data| {
                    pos += row_data.len;
                } else {
                    // Empty row set on failure.
                    if (pos + 6 > buf.len) return null;
                    std.mem.writeInt(u16, buf[pos..][0..2], 0, .big);
                    pos += 2;
                    std.mem.writeInt(u32, buf[pos..][0..4], 0, .big);
                    pos += 4;
                }
            }
        }

        // Send render results.
        if (!protocol.write_frame(self.fd, buf[0..pos])) {
            self.handle_disconnect();
            return null;
        }

        // Receive html_response.
        // [u8 tag][html_bytes...]
        const resp = protocol.read_frame(self.fd, self.recv_buf) orelse {
            self.handle_disconnect();
            return null;
        };

        if (resp.len < 1) {
            self.handle_disconnect();
            return null;
        }

        if (resp[0] != @intFromEnum(protocol.MessageTag.html_response)) {
            log.err("render: unexpected tag {d}", .{resp[0]});
            self.handle_disconnect();
            return null;
        }

        self.html = resp[1..];
        return self.html;
    }
};
