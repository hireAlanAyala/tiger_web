//! Sidecar client — CALL/RESULT protocol state machine.
//!
//! Pure protocol logic — no IO calls. The message bus handles all
//! socket communication. This module processes frames delivered by
//! the bus and builds frames for sending.
//!
//! State machine: call_submit → on_frame (loop) → complete/failed.
//! The server's bus callback drives on_frame when frames arrive.
//!
//! Connection lifecycle is handled by the MessageBus (listen, accept,
//! reconnect). The SidecarClient receives on_close when the bus
//! connection terminates.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const MessageBusType = @import("framework/message_bus.zig").MessageBusType;
const ConnectionType = @import("framework/message_bus.zig").ConnectionType;

const log = std.log.scoped(.sidecar);

pub const SidecarClient = struct {
    pub const max_queries_per_call = protocol.queries_max;

    // Bus options — sidecar is serial (2 slots: CALL + QUERY_RESULT).
    pub const bus_options = .{ .send_queue_max = 2, .frame_max = protocol.frame_max };

    // Sized to 3 × frame_max: each round trip copies at most one
    // frame's worth of data. Three round trips = 3 × frame_max.
    const state_buf_max = 3 * protocol.frame_max;

    // Per-request state — copied into owned memory, not aliased.
    state_buf: *[state_buf_max]u8,
    state_pos: usize = 0,

    // Write execution state.
    handle_writes: []const u8 = "",
    handle_write_count: u8 = 0,

    // CALL/RESULT state machine.
    call_state: CallState = .idle,
    call_query_count: u32 = 0,
    result_flag: protocol.ResultFlag = .success,
    result_data: []const u8 = "",
    /// Prefetch result — stored between prefetch and handle phases.
    prefetch_result: []const u8 = "",

    pub fn init() SidecarClient {
        const state = std.heap.page_allocator.create([state_buf_max]u8) catch
            @panic("sidecar: failed to allocate state buffer");
        return .{ .state_buf = state };
    }

    /// Copy data into state_buf. Returns a slice into state_buf
    /// that owns the data. Immune to recv buffer overwrites.
    pub fn copy_state(self: *SidecarClient, data: []const u8) []const u8 {
        if (data.len == 0) return "";
        const start = self.state_pos;
        assert(start + data.len <= self.state_buf.len);
        @memcpy(self.state_buf[start..][0..data.len], data);
        self.state_pos += data.len;
        return self.state_buf[start..][0..data.len];
    }

    // =================================================================
    // CALL/RESULT state machine
    // =================================================================

    pub const CallState = enum {
        idle,
        receiving, // CALL sent, waiting for frames
        complete, // RESULT received
        failed, // Protocol error or disconnect
    };

    /// Query dispatch function type — same as before.
    pub const QueryFn = *const fn (
        context: *anyopaque,
        sql: []const u8,
        params_buf: []const u8,
        param_count: u8,
        mode: protocol.QueryMode,
        out_buf: []u8,
    ) ?[]const u8;

    /// Submit a CALL frame via the bus. Builds the CALL payload
    /// into a pool message (zero-copy) and sends it.
    pub fn call_submit(self: *SidecarClient, bus: anytype, function_name: []const u8, args: []const u8) bool {
        assert(self.call_state == .idle);

        const pool = &bus.pool;
        const msg = pool.get_message();

        const header_size = @TypeOf(bus.*).Connection.frame_header_size;
        const call_len = protocol.build_call(
            msg.buffer[header_size..],
            0, // request_id
            function_name,
            args,
        ) orelse {
            log.warn("call: frame too large for {s}", .{function_name});
            pool.unref(msg);
            return false;
        };

        bus.send_message(msg, @intCast(call_len));
        self.call_state = .receiving;
        self.call_query_count = 0;
        return true;
    }

    /// Process one received frame. Called by the server's bus
    /// on_frame callback. Same logic as the old on_recv but with
    /// no IO calls — the bus handles framing and CRC validation.
    ///
    /// For QUERY frames: builds QUERY_RESULT into a pool message
    /// and sends via the bus (zero-copy).
    pub fn on_frame(
        self: *SidecarClient,
        bus: anytype,
        frame: []const u8,
        query_fn: ?QueryFn,
        query_ctx: ?*anyopaque,
        comptime queries_max: u32,
    ) void {
        assert(self.call_state == .receiving);

        const parsed = protocol.parse_sidecar_frame(frame) orelse {
            log.warn("call: invalid frame from sidecar", .{});
            self.call_state = .failed;
            return;
        };

        switch (parsed.tag) {
            .result => {
                const result = protocol.parse_result_payload(parsed.payload) orelse {
                    log.warn("call: invalid RESULT payload", .{});
                    self.call_state = .failed;
                    return;
                };
                self.result_flag = result.flag;
                self.result_data = result.data;
                self.call_state = .complete;
            },
            .query => {
                if (query_fn == null) {
                    log.warn("call: QUERY received during no-query CALL", .{});
                    self.call_state = .failed;
                    return;
                }

                if (self.call_query_count >= queries_max) {
                    log.warn("call: exceeded max queries ({d})", .{queries_max});
                    self.call_state = .failed;
                    return;
                }
                self.call_query_count += 1;

                const query = protocol.parse_query_payload(parsed.payload) orelse {
                    log.warn("call: invalid QUERY payload", .{});
                    self.call_state = .failed;
                    return;
                };

                // Build QUERY_RESULT into a pool message (zero-copy).
                const pool = &bus.pool;
                const msg = pool.get_message();
                const header_size = @TypeOf(bus.*).Connection.frame_header_size;
                const qr_buf = msg.buffer[header_size..];

                // QUERY_RESULT header: [tag: u8][request_id: u32 BE][query_id: u16 BE]
                qr_buf[0] = @intFromEnum(protocol.CallTag.query_result);
                std.mem.writeInt(u32, qr_buf[1..5], parsed.request_id, .big);
                std.mem.writeInt(u16, qr_buf[5..7], query.query_id, .big);

                // Execute SQL — row set written directly after the 7-byte header.
                const row_set = query_fn.?(
                    query_ctx.?,
                    query.sql,
                    query.params_buf,
                    query.param_count,
                    query.mode,
                    qr_buf[7..],
                ) orelse "";

                const qr_total: u32 = @intCast(7 + row_set.len);
                bus.send_message(msg, qr_total);

                // Stay in .receiving — more frames expected.
            },
            else => unreachable,
        }
    }

    /// Called by the server when the bus connection closes.
    /// Resets in-flight state so the next accept starts clean.
    pub fn on_close(self: *SidecarClient) void {
        if (self.call_state == .receiving) {
            log.warn("sidecar disconnected during exchange", .{});
            self.call_state = .failed;
        }
        self.reset_request_state();
    }

    pub fn reset_call_state(self: *SidecarClient) void {
        self.call_state = .idle;
        self.call_query_count = 0;
        self.result_flag = .success;
        self.result_data = "";
    }

    fn reset_request_state(self: *SidecarClient) void {
        self.state_pos = 0;
        self.handle_writes = "";
        self.handle_write_count = 0;
    }

    // =================================================================
    // Execute writes
    // =================================================================

    /// Execute handle's write queue against storage.
    pub fn execute_writes(self: *SidecarClient, storage: anytype) bool {
        const data = self.handle_writes;
        if (self.handle_write_count == 0) return true;

        var dpos: usize = 0;
        for (0..self.handle_write_count) |_| {
            if (dpos + 2 > data.len) return false;
            const sql_len = std.mem.readInt(u16, data[dpos..][0..2], .big);
            dpos += 2;
            if (dpos + sql_len > data.len) return false;
            const sql = data[dpos..][0..sql_len];
            dpos += sql_len;

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
