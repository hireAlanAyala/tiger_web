//! Sidecar client — CALL/RESULT protocol state machine.
//!
//! Pure protocol logic — no IO calls. The message bus handles all
//! socket communication. This module processes frames delivered by
//! the bus and builds frames for sending.
//!
//! Parameterized on Bus type (comptime): the caller resolves the
//! concrete bus. Production: MessageBusType(IO, options). Sim:
//! SimSidecarBus. Matches TigerBeetle's ClientType(MessageBus).
//!
//! State machine: call_submit → on_frame (loop) → complete/failed.
//! The server's bus callback drives on_frame when frames arrive.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.sidecar);

/// Sidecar protocol state machine, parameterized on Bus type.
/// The caller resolves the Bus: app.zig for production (MessageBusType),
/// sim for testing (SimSidecarBus). This module never imports message_bus.
pub fn SidecarClientType(comptime Bus: type) type {
    return struct {
        const Self = @This();

        pub const max_queries_per_call = protocol.queries_max;
        pub const BusType = Bus;

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
        /// The request_id sent in the most recent CALL. Validated
        /// against the request_id in every RESULT and QUERY frame.
        /// Detects stale or mismatched responses.
        expected_request_id: u32 = 0,
        /// Set to true on protocol violations (invalid frame, request_id
        /// mismatch, query limit exceeded). The server checks this after
        /// process_sidecar_frame and terminates the connection.
        protocol_violation: bool = false,
        result_flag: protocol.ResultFlag = .success,
        result_data: []const u8 = "",
        /// Prefetch result — stored between prefetch and handle phases.
        prefetch_result: []const u8 = "",

        pub fn init() Self {
            const state = std.heap.page_allocator.create([state_buf_max]u8) catch
                @panic("sidecar: failed to allocate state buffer");
            return .{ .state_buf = state };
        }

        /// Copy data into state_buf. Returns a slice into state_buf
        /// that owns the data. Immune to recv buffer overwrites.
        pub fn copy_state(self: *Self, data: []const u8) []const u8 {
            if (data.len == 0) return "";
            const start = self.state_pos;
            assert(start + data.len <= self.state_buf.len);
            @memcpy(self.state_buf[start..][0..data.len], data);
            self.state_pos += data.len;
            return self.state_buf[start..][0..data.len];
        }

        // =============================================================
        // CALL/RESULT state machine
        // =============================================================

        pub const CallState = enum {
            idle,
            receiving, // CALL sent, waiting for frames
            complete, // RESULT received
            failed, // Protocol error or disconnect
        };

        /// Query dispatch function type.
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
        /// Returns false if the bus connection is closed (sidecar
        /// disconnected) or the frame is too large. The caller
        /// treats false as busy/fail.
        pub fn call_submit(self: *Self, bus: *Bus, connection_index: u8, function_name: []const u8, args: []const u8, request_id: u32) bool {
            assert(self.call_state == .idle);

            // Don't submit if the sidecar connection isn't ready.
            if (!bus.is_connection_ready(connection_index)) {
                log.warn("call: connection {d} not ready for {s}", .{ connection_index, function_name });
                return false;
            }

            // Don't submit if the send queue is full.
            if (!bus.can_send_to(connection_index)) {
                log.warn("call: send queue full on connection {d} for {s}", .{ connection_index, function_name });
                return false;
            }

            const msg = bus.get_message();
            const call_len = protocol.build_call(
                msg.buffer[Bus.frame_header_size..],
                request_id,
                function_name,
                args,
            ) orelse {
                log.warn("call: frame too large for {s}", .{function_name});
                bus.unref(msg);
                return false;
            };

            bus.send_message_to(connection_index, msg, @intCast(call_len));
            self.call_state = .receiving;
            self.call_query_count = 0;
            self.expected_request_id = request_id;
            return true;
        }

        /// Process one received frame. Called by the server's bus
        /// on_frame callback. Same logic as the old on_recv but
        /// with no IO calls.
        pub fn on_frame(
            self: *Self,
            bus: *Bus,
            connection_index: u8,
            frame: []const u8,
            query_fn: ?QueryFn,
            query_ctx: ?*anyopaque,
            comptime queries_max: u32,
        ) void {
            // Don't assert — an unsolicited frame from a rogue sidecar
            // must not crash the server. Detect and kill instead.
            if (self.call_state != .receiving) {
                log.warn("call: unsolicited frame (call_state={s})", .{@tagName(self.call_state)});
                self.call_state = .failed;
                self.protocol_violation = true;
                return;
            }

            const parsed = protocol.parse_sidecar_frame(frame) orelse {
                log.warn("call: invalid frame from sidecar", .{});
                self.call_state = .failed;
                self.protocol_violation = true;
                return;
            };

            // Validate request_id — detect stale or mismatched responses.
            if (parsed.request_id != self.expected_request_id) {
                log.warn("call: request_id mismatch: expected {d}, got {d}", .{
                    self.expected_request_id, parsed.request_id,
                });
                self.call_state = .failed;
                self.protocol_violation = true;
                return;
            }

            switch (parsed.tag) {
                .result => {
                    const result = protocol.parse_result_payload(parsed.payload) orelse {
                        log.warn("call: invalid RESULT payload", .{});
                        self.call_state = .failed;
                        self.protocol_violation = true;
                        return;
                    };
                    self.result_flag = result.flag;
                    // copy_state: result.data is a slice into the bus's recv
                    // buffer which is compacted after on_frame returns. Must
                    // copy into owned state_buf before the slice is invalidated.
                    self.result_data = self.copy_state(result.data);
                    self.call_state = .complete;
                },
                .query => {
                    if (query_fn == null) {
                        log.warn("call: QUERY received during no-query CALL", .{});
                        self.call_state = .failed;
                        self.protocol_violation = true;
                        return;
                    }

                    if (self.call_query_count >= queries_max) {
                        log.warn("call: exceeded max queries ({d})", .{queries_max});
                        self.call_state = .failed;
                        self.protocol_violation = true;
                        return;
                    }
                    self.call_query_count += 1;

                    const query = protocol.parse_query_payload(parsed.payload) orelse {
                        log.warn("call: invalid QUERY payload", .{});
                        self.call_state = .failed;
                        return;
                    };

                    // Check send queue before allocating — a rogue sidecar
                    // bursting QUERYs must not assert-crash the server.
                    if (!bus.can_send_to(connection_index)) {
                        log.warn("call: send queue full, cannot queue QUERY_RESULT", .{});
                        self.call_state = .failed;
                        self.protocol_violation = true;
                        return;
                    }

                    // Build QUERY_RESULT into a pool message (zero-copy).
                    const msg = bus.get_message();
                    const qr_buf = msg.buffer[Bus.frame_header_size..];

                    // QUERY_RESULT: [tag][request_id: u32 BE][query_id: u16 BE]
                    qr_buf[0] = @intFromEnum(protocol.CallTag.query_result);
                    std.mem.writeInt(u32, qr_buf[1..5], parsed.request_id, .big);
                    std.mem.writeInt(u16, qr_buf[5..7], query.query_id, .big);

                    // Execute SQL — row set after the 7-byte header.
                    const row_set = query_fn.?(
                        query_ctx.?,
                        query.sql,
                        query.params_buf,
                        query.param_count,
                        query.mode,
                        qr_buf[7..],
                    ) orelse "";

                    const qr_total: u32 = @intCast(7 + row_set.len);
                    bus.send_message_to(connection_index, msg, qr_total);

                    // Stay in .receiving — more frames expected.
                },
                else => unreachable,
            }
        }

        /// Called when the bus connection closes.
        pub fn on_close(self: *Self) void {
            if (self.call_state == .receiving) {
                log.warn("sidecar disconnected during exchange", .{});
                self.call_state = .failed;
            }
            self.reset_request_state();
        }

        pub fn reset_call_state(self: *Self) void {
            self.call_state = .idle;
            self.call_query_count = 0;
            self.expected_request_id = 0;
            self.protocol_violation = false;
            self.result_flag = .success;
            self.result_data = "";
        }

        pub fn reset_request_state(self: *Self) void {
            self.state_pos = 0;
            self.handle_writes = "";
            self.handle_write_count = 0;
        }

        // =============================================================
        // Execute writes
        // =============================================================

        pub fn execute_writes(self: *Self, storage: anytype) bool {
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
}
