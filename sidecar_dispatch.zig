//! Sidecar dispatch v2 — pipelined stateless protocol.
//!
//! 4 RTs per request: route, prefetch, handle, render.
//! Every RT is synchronous on the TS side. The framework holds all
//! state between RTs. Multiple requests in different stages
//! simultaneously — pipelined across one sidecar connection.
//!
//! No SidecarClient — the dispatch module owns the frame protocol
//! directly. Each pipeline entry is self-contained: own request_id,
//! own stage, own result buffers sized to stage maximums.
//!
//! The framework executes prefetch SQL and handle writes. The sidecar
//! declares queries and writes as [sql, ...params] arrays. Single
//! storage implementation — no db library in the sidecar.
//!
//! Write-boundary ordering: prefetch for request N waits until all
//! prior mutations' writes have committed. O(1) watermark check.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const http = @import("framework/http.zig");

const log = std.log.scoped(.sidecar_dispatch);

pub fn SidecarDispatchType(comptime StorageParam: type, comptime Bus: type) type {
    return struct {
        const Self = @This();
        const max_entries = @import("framework/constants.zig").pipeline_slots_max;

        // Max result sizes per stage (not frame_max — sized to actual need).
        const route_result_max = 1 + 16 + message.body_max; // operation + id + body
        const prefetch_result_max = 2 + protocol.sql_max + 1 + 1024; // sql_len + sql + param_count + params
        const handle_result_max = 2 + 256 + 1 + 1 + protocol.writes_max * (2 + protocol.sql_max + 1 + 256); // status + session + writes

        // =============================================================
        // Pipeline entry — per-request state, self-contained
        // =============================================================

        pub const Stage = enum {
            free,
            route_pending,
            route_complete,
            prefetch_pending,
            prefetch_complete,
            sql_executing,
            sql_complete,
            handle_pending,
            handle_complete,
            write_pending,
            write_complete,
            render_pending,
            render_complete,
        };

        pub const Entry = struct {
            stage: Stage = .free,
            request_id: u32 = 0,
            sequence: u32 = 0,

            // Connection that originated this request.
            connection: ?*anyopaque = null,

            // Accumulated across RTs.
            operation: message.Operation = .root,
            msg: message.Message = std.mem.zeroes(message.Message),
            is_mutation: bool = false,

            // Per-entry result buffers — sized to stage maximums.
            route_buf: [route_result_max]u8 = undefined,
            route_len: usize = 0,
            prefetch_buf: [prefetch_result_max]u8 = undefined,
            prefetch_len: usize = 0,
            handle_buf: [handle_result_max]u8 = undefined,
            handle_len: usize = 0,

            // Parsed prefetch declaration.
            prefetch_mode: protocol.QueryMode = .query_all,
            prefetch_sql: []const u8 = "",
            prefetch_param_count: u8 = 0,
            prefetch_params: []const u8 = "",

            // Prefetch result (rows serialized by framework).
            rows_data: []const u8 = "",

            // Parsed handle result.
            handle_status: message.Status = .ok,
            handle_session_action: message.SessionAction = .none,
            handle_write_count: u8 = 0,
            handle_writes: []const u8 = "",

            // Render result — stored in shared render_buf, not per-entry.
            html: []const u8 = "",

            pub fn reset(self: *Entry) void {
                const stage_default: Stage = .free;
                self.stage = stage_default;
                self.request_id = 0;
                self.sequence = 0;
                self.connection = null;
                self.operation = .root;
                self.msg = std.mem.zeroes(message.Message);
                self.is_mutation = false;
                self.route_len = 0;
                self.prefetch_len = 0;
                self.handle_len = 0;
                self.prefetch_sql = "";
                self.prefetch_param_count = 0;
                self.prefetch_params = "";
                self.rows_data = "";
                self.handle_status = .ok;
                self.handle_session_action = .none;
                self.handle_write_count = 0;
                self.handle_writes = "";
                self.html = "";
            }
        };

        // =============================================================
        // Dispatch state
        // =============================================================

        entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
        next_request_id: u32 = 1,
        next_sequence: u32 = 1,

        // Write-boundary watermark: O(1) check instead of O(N) scan.
        // Tracks the highest sequence number of a committed mutation.
        // Prefetch for entry with seq S can proceed if all mutations
        // with seq < S have committed — i.e., pending_mutations == 0
        // or the lowest pending mutation seq > S.
        last_committed_mutation_seq: u32 = 0,
        pending_mutation_count: u32 = 0,
        lowest_pending_mutation_seq: u32 = std.math.maxInt(u32),

        // Re-entrancy guard (TB pattern).
        dispatch_entered: bool = false,

        // Infrastructure — set during wire.
        bus: ?*Bus = null,
        connection_index: u8 = 0,

        // Shared render buffer — only one entry renders at a time.
        // Render is the last stage before encoding into send_buf.
        render_buf: [http.send_buf_max]u8 = undefined,

        // Shared prefetch SQL output buffer — only one prefetch
        // executes at a time (synchronous within advance).
        sql_out_buf: [protocol.frame_max]u8 = undefined,

        // =============================================================
        // Public interface
        // =============================================================

        pub fn acquire_entry(self: *Self) ?*Entry {
            for (&self.entries) |*entry| {
                if (entry.stage == .free) return entry;
            }
            return null;
        }

        /// Start a new request: send RT1 (route) CALL.
        pub fn start_request(
            self: *Self,
            entry: *Entry,
            method: http.Method,
            path: []const u8,
            body: []const u8,
            connection: *anyopaque,
        ) bool {
            const b = self.bus orelse return false;

            const request_id = self.next_request_id;
            self.next_request_id +%= 1;

            // Build route CALL args.
            const args_max = 1 + 2 + http.max_header_size + 2 + http.body_max;
            var args_buf: [args_max]u8 = undefined;
            var pos: usize = 0;

            args_buf[pos] = @intFromEnum(method);
            pos += 1;
            std.mem.writeInt(u16, args_buf[pos..][0..2], @intCast(path.len), .big);
            pos += 2;
            @memcpy(args_buf[pos..][0..path.len], path);
            pos += path.len;
            std.mem.writeInt(u16, args_buf[pos..][0..2], @intCast(body.len), .big);
            pos += 2;
            if (body.len > 0) {
                @memcpy(args_buf[pos..][0..body.len], body);
                pos += body.len;
            }

            if (!self.send_call(b, "route", args_buf[0..pos], request_id)) {
                return false;
            }

            entry.stage = .route_pending;
            entry.request_id = request_id;
            entry.connection = connection;
            log.debug("start_request: sent route CALL request_id={d}", .{request_id});
            return true;
        }

        /// Process a received frame — route to entry by request_id.
        pub fn on_frame(self: *Self, frame: []const u8, storage: *StorageParam) void {
            defer self.invariants();

            log.debug("on_frame: len={d} tag=0x{x:0>2}", .{ frame.len, if (frame.len > 0) frame[0] else 0 });

            if (frame.len < 5) {
                log.warn("dispatch: frame too short ({d} bytes)", .{frame.len});
                return;
            }

            // Parse frame header.
            const parsed = protocol.parse_sidecar_frame(frame) orelse {
                log.warn("dispatch: invalid frame", .{});
                return;
            };
            if (parsed.tag != .result) {
                log.warn("dispatch: unexpected tag {s}", .{@tagName(parsed.tag)});
                return;
            }

            const result = protocol.parse_result_payload(parsed.payload) orelse {
                log.warn("dispatch: invalid RESULT payload", .{});
                return;
            };

            const entry = self.find_entry_by_request_id(parsed.request_id) orelse {
                log.warn("dispatch: no entry for request_id {d}", .{parsed.request_id});
                return;
            };

            if (result.flag != .success) {
                entry.reset();
                return;
            }

            // Copy result data into entry's stage-specific buffer.
            switch (entry.stage) {
                .route_pending => {
                    const len = @min(result.data.len, route_result_max);
                    @memcpy(entry.route_buf[0..len], result.data[0..len]);
                    entry.route_len = len;
                    self.parse_route_result(entry);
                },
                .prefetch_pending => {
                    const len = @min(result.data.len, prefetch_result_max);
                    @memcpy(entry.prefetch_buf[0..len], result.data[0..len]);
                    entry.prefetch_len = len;
                    self.parse_prefetch_result(entry);
                },
                .handle_pending => {
                    const len = @min(result.data.len, handle_result_max);
                    @memcpy(entry.handle_buf[0..len], result.data[0..len]);
                    entry.handle_len = len;
                    self.parse_handle_result(entry);
                },
                .render_pending => {
                    const len = @min(result.data.len, http.send_buf_max);
                    @memcpy(self.render_buf[0..len], result.data[0..len]);
                    entry.html = self.render_buf[0..len];
                    entry.stage = .render_complete;
                },
                else => {
                    log.warn("dispatch: RESULT in unexpected stage {s}", .{@tagName(entry.stage)});
                },
            }

            // Advance the pipeline after processing.
            self.advance(storage);
        }

        /// Advance all entries that can progress. Called after on_frame
        /// and after write commits. Loops until no more progress (TB's
        /// bounded loop pattern — max iterations = entries × stages).
        pub fn advance(self: *Self, storage: *StorageParam) void {
            // Re-entrancy guard.
            if (self.dispatch_entered) return;
            self.dispatch_entered = true;
            defer {
                self.dispatch_entered = false;
                self.invariants();
            }

            const b = self.bus orelse return;
            const max_iterations = max_entries * 13; // entries × stages
            var iteration: usize = 0;
            var progress = true;

            while (progress and iteration < max_iterations) : (iteration += 1) {
                progress = false;

            for (&self.entries) |*entry| {
                const prev_stage = entry.stage;
                switch (entry.stage) {
                    .route_complete => {
                        entry.sequence = self.next_sequence;
                        self.next_sequence +%= 1;
                        entry.is_mutation = entry.operation.is_mutation();
                        if (entry.is_mutation) {
                            self.pending_mutation_count += 1;
                            if (entry.sequence < self.lowest_pending_mutation_seq) {
                                self.lowest_pending_mutation_seq = entry.sequence;
                            }
                        }
                        var args_buf: [17]u8 = undefined;
                        args_buf[0] = @intFromEnum(entry.operation);
                        std.mem.writeInt(u128, args_buf[1..17], entry.msg.id, .little);
                        if (self.send_call(b, "prefetch", &args_buf, entry.request_id)) {
                            entry.stage = .prefetch_pending;
                        }
                    },
                    .prefetch_complete => {
                        if (entry.prefetch_sql.len > 0) {
                            if (!self.can_prefetch(entry)) continue;
                            self.execute_prefetch_sql(entry, storage);
                        } else {
                            entry.rows_data = "";
                            entry.stage = .sql_complete;
                        }
                    },
                    .sql_complete => {
                        if (self.send_call(b, "handle", entry.rows_data, entry.request_id)) {
                            entry.stage = .handle_pending;
                        }
                    },
                    .handle_complete => {
                        entry.stage = .write_pending;
                    },
                    .write_complete => {
                        const args = [_]u8{@intFromEnum(entry.handle_status)};
                        if (self.send_call(b, "render", &args, entry.request_id)) {
                            entry.stage = .render_pending;
                        }
                    },
                    else => {},
                }
                if (entry.stage != prev_stage) progress = true;
            }
            } // while
        }

        /// Write-boundary check: O(1) via watermark.
        fn can_prefetch(self: *const Self, entry: *const Entry) bool {
            if (self.pending_mutation_count == 0) return true;
            // All pending mutations must have seq >= entry.seq for this
            // entry to proceed. If the lowest pending mutation has a
            // lower seq, we must wait.
            return self.lowest_pending_mutation_seq >= entry.sequence;
        }

        /// Notify that a write has committed for the given entry.
        pub fn write_committed(self: *Self, entry: *Entry) void {
            assert(entry.stage == .write_pending);
            entry.stage = .write_complete;
            if (entry.is_mutation) {
                self.last_committed_mutation_seq = @max(self.last_committed_mutation_seq, entry.sequence);
                assert(self.pending_mutation_count > 0);
                self.pending_mutation_count -= 1;
                // Recompute lowest pending mutation seq.
                self.recompute_lowest_pending_mutation();
            }
        }

        pub fn release_entry(self: *Self, entry: *Entry) void {
            _ = self;
            entry.reset();
        }

        /// Reset all entries (sidecar disconnect recovery).
        pub fn reset_all(self: *Self) void {
            for (&self.entries) |*entry| {
                entry.reset();
            }
            self.pending_mutation_count = 0;
            self.lowest_pending_mutation_seq = std.math.maxInt(u32);
        }

        pub fn any_pending(self: *const Self) bool {
            for (&self.entries) |*entry| {
                switch (entry.stage) {
                    .route_pending, .prefetch_pending, .handle_pending, .render_pending => return true,
                    else => {},
                }
            }
            return false;
        }

        // =============================================================
        // Invariants (TB pattern)
        // =============================================================

        fn invariants(self: *const Self) void {
            var active_count: u32 = 0;
            var seen_request_ids: [max_entries]u32 = .{0} ** max_entries;
            var seen_count: usize = 0;
            var mutations_pending: u32 = 0;

            for (&self.entries) |*entry| {
                if (entry.stage == .free) continue;
                active_count += 1;

                // No duplicate request_ids among active entries.
                for (seen_request_ids[0..seen_count]) |seen| {
                    assert(seen != entry.request_id);
                }
                seen_request_ids[seen_count] = entry.request_id;
                seen_count += 1;

                // Valid operation for non-free entries.
                assert(entry.operation != .root or entry.stage == .route_pending);

                // Mutation tracking consistency.
                if (entry.is_mutation) {
                    switch (entry.stage) {
                        .route_complete, .prefetch_pending, .prefetch_complete,
                        .sql_executing, .sql_complete, .handle_pending,
                        .handle_complete, .write_pending => {
                            mutations_pending += 1;
                        },
                        else => {},
                    }
                }
            }

            assert(active_count <= max_entries);
            assert(self.pending_mutation_count == mutations_pending);
        }

        // =============================================================
        // Frame sending — direct to bus, no SidecarClient
        // =============================================================

        fn send_call(self: *Self, b: *Bus, function_name: []const u8, args: []const u8, request_id: u32) bool {
            if (!b.is_connection_ready(self.connection_index)) {
                log.warn("send_call: connection {d} not ready for {s}", .{ self.connection_index, function_name });
                return false;
            }
            if (!b.can_send_to(self.connection_index)) {
                log.warn("send_call: send queue full for {s}", .{function_name});
                return false;
            }

            const msg = b.get_message();
            const call_len = protocol.build_call(
                msg.buffer[Bus.frame_header_size..],
                request_id,
                function_name,
                args,
            ) orelse {
                b.unref(msg);
                return false;
            };

            b.send_message_to(self.connection_index, msg, @intCast(call_len));
            return true;
        }

        // =============================================================
        // Prefetch SQL execution
        // =============================================================

        fn execute_prefetch_sql(self: *Self, entry: *Entry, storage: *StorageParam) void {
            entry.stage = .sql_executing;

            log.debug("execute_prefetch_sql: sql_len={d} param_count={d}", .{ entry.prefetch_sql.len, entry.prefetch_param_count });

            const result = storage.query_raw(
                entry.prefetch_sql,
                entry.prefetch_params,
                entry.prefetch_param_count,
                entry.prefetch_mode,
                &self.sql_out_buf,
            );

            log.debug("execute_prefetch_sql: result={s}", .{if (result != null) "data" else "null"});
            if (result) |rows| {
                // Copy rows into entry — but rows may be large.
                // Use the shared sql_out_buf; the data is valid until
                // the next execute_prefetch_sql call. Since advance()
                // is synchronous and single-threaded, this is safe —
                // the entry moves to sql_complete and send_handle
                // copies rows into the CALL frame before the next
                // prefetch executes.
                entry.rows_data = rows;
            } else {
                entry.rows_data = "";
            }

            entry.stage = .sql_complete;
        }

        // =============================================================
        // RESULT parsers
        // =============================================================

        fn parse_route_result(self: *Self, entry: *Entry) void {
            _ = self;
            const data = entry.route_buf[0..entry.route_len];
            if (data.len < 17) {
                entry.reset();
                return;
            }

            const op = std.meta.intToEnum(message.Operation, data[0]) catch {
                entry.reset();
                return;
            };
            if (op == .root) {
                entry.reset();
                return;
            }

            entry.operation = op;
            entry.msg = std.mem.zeroes(message.Message);
            entry.msg.operation = op;
            entry.msg.id = std.mem.readInt(u128, data[1..17], .little);
            if (data.len > 17) {
                const copy_len = @min(data.len - 17, message.body_max);
                @memcpy(entry.msg.body[0..copy_len], data[17..][0..copy_len]);
            }

            entry.stage = .route_complete;
        }

        fn parse_prefetch_result(self: *Self, entry: *Entry) void {
            _ = self;
            const data = entry.prefetch_buf[0..entry.prefetch_len];

            if (data.len == 0) {
                entry.prefetch_sql = "";
                entry.prefetch_param_count = 0;
                entry.prefetch_params = "";
                entry.stage = .prefetch_complete;
                return;
            }

            if (data.len < 4) { // mode(1) + sql_len(2) + param_count(1)
                entry.reset();
                return;
            }

            var pos: usize = 0;
            // Mode: 0x00 = query (single row), 0x01 = queryAll.
            entry.prefetch_mode = if (data[pos] == 0x00) .query else .query_all;
            pos += 1;
            const sql_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + sql_len + 1 > data.len) {
                entry.reset();
                return;
            }

            // Slices point into entry.prefetch_buf — stable lifetime.
            entry.prefetch_sql = data[pos..][0..sql_len];
            pos += sql_len;
            entry.prefetch_param_count = data[pos];
            pos += 1;
            entry.prefetch_params = if (pos < data.len) data[pos..] else "";

            entry.stage = .prefetch_complete;
        }

        fn parse_handle_result(self: *Self, entry: *Entry) void {
            _ = self;
            const data = entry.handle_buf[0..entry.handle_len];

            if (data.len < 4) {
                entry.handle_status = .storage_error;
                entry.stage = .handle_complete;
                return;
            }

            var pos: usize = 0;
            const status_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + status_len + 2 > data.len) {
                entry.handle_status = .storage_error;
                entry.stage = .handle_complete;
                return;
            }

            entry.handle_status = message.Status.from_string(data[pos..][0..status_len]) orelse .storage_error;
            pos += status_len;

            entry.handle_session_action = switch (data[pos]) {
                0 => .none,
                1 => .set_authenticated,
                2 => .clear,
                else => .none,
            };
            pos += 1;

            entry.handle_write_count = data[pos];
            pos += 1;
            // Writes slice points into entry.handle_buf — stable lifetime.
            entry.handle_writes = if (entry.handle_write_count > 0 and pos < data.len) data[pos..] else "";

            entry.stage = .handle_complete;
        }

        // =============================================================
        // Internal helpers
        // =============================================================

        fn find_entry_by_request_id(self: *Self, request_id: u32) ?*Entry {
            for (&self.entries) |*entry| {
                if (entry.stage != .free and entry.request_id == request_id) {
                    return entry;
                }
            }
            return null;
        }

        fn recompute_lowest_pending_mutation(self: *Self) void {
            var lowest: u32 = std.math.maxInt(u32);
            for (&self.entries) |*entry| {
                if (entry.stage == .free) continue;
                if (!entry.is_mutation) continue;
                switch (entry.stage) {
                    .route_complete, .prefetch_pending, .prefetch_complete,
                    .sql_executing, .sql_complete, .handle_pending,
                    .handle_complete, .write_pending => {
                        if (entry.sequence < lowest) lowest = entry.sequence;
                    },
                    else => {},
                }
            }
            self.lowest_pending_mutation_seq = lowest;
        }
    };
}
