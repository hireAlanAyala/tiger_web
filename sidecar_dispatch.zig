//! Sidecar dispatch — SHM 1-RT/2-RT protocol.
//!
//! 1-RT: server does route + prefetch natively, sends handle_render CALL.
//! 2-RT: sidecar does route + prefetch (returns SQL declarations),
//!       server executes SQL, then sends handle_render CALL.
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

pub fn SidecarDispatchType(comptime Bus: type) type {
    return struct {
        const Self = @This();
        const max_entries = @import("framework/constants.zig").pipeline_slots_max;

        // Max result sizes per stage — derived from domain constants, not literals.
        const route_result_max = 1 + 16 + message.body_max;
        const status_max = 64;
        const write_params_max = 16 * (1 + 8); // 16 params × (tag + i64)
        const handle_result_max = 2 + status_max + 1 + 1 + protocol.writes_max * (2 + protocol.sql_max + 1 + write_params_max);

        comptime {
            assert(max_entries > 0);
            assert(route_result_max > 0);
            assert(handle_result_max > 0);
            assert(status_max >= "storage_error".len);
            // 1 + 8 = type_tag + i64, the largest fixed-size param.
            assert(write_params_max == 16 * (1 + 8));
        }

        // =============================================================
        // Pipeline entry — per-request state, self-contained
        // =============================================================

        pub const Stage = enum {
            free,
            // 1-RT: handle+render combined.
            combined_pending,
            combined_complete,
            // 2-RT: route+prefetch combined, then handle+render.
            route_prefetch_pending,
            route_prefetch_complete, // SQL declarations received, execute SQL
            // After SQL execution → combined_pending for handle_render CALL.
            // Shared stages — writes, then render.
            write_pending,
            write_complete,
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
            handle_buf: [handle_result_max]u8 = undefined,
            handle_len: usize = 0,

            // Parsed handle result.
            handle_status: message.Status = .ok,
            handle_session_action: message.SessionAction = .none,
            handle_write_count: u8 = 0,
            handle_writes: []const u8 = "",

            // Render result — stored in shared render_buf, not per-entry.
            html: []const u8 = "",
            // 1-RT: HTML stored in handle_buf at this offset until
            // render_complete, when it's copied to render_buf.
            html_offset: usize = 0,
            html_len: usize = 0,
            body_len: u16 = 0, // actual body length for 2-RT path

            pub fn reset(self: *Entry) void {
                self.stage = .free;
                self.request_id = 0;
                self.sequence = 0;
                self.connection = null;
                self.operation = .root;
                self.msg = std.mem.zeroes(message.Message);
                self.is_mutation = false;
                self.route_len = 0;
                self.handle_len = 0;
                self.handle_status = .ok;
                self.handle_session_action = .none;
                self.handle_write_count = 0;
                self.handle_writes = "";
                self.html = "";
                self.html_offset = 0;
                self.html_len = 0;
                self.body_len = 0;
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


        // =============================================================
        // Public interface
        // =============================================================

        pub fn acquire_entry(self: *Self) ?*Entry {
            for (&self.entries) |*entry| {
                if (entry.stage == .free) {
                    // Zero buffers to prevent stale data leaks between requests.
                    @memset(&entry.route_buf, 0);
                    @memset(&entry.handle_buf, 0);
                    return entry;
                }
            }
            return null;
        }

        /// Start a 2-RT request: send route_prefetch CALL.
        /// Same args format as start_request (method + path + body).
        /// The sidecar runs route() + prefetch() and returns SQL declarations.
        pub fn start_request_2rt(
            self: *Self,
            entry: *Entry,
            method: http.Method,
            path: []const u8,
            body: []const u8,
            connection: *anyopaque,
        ) bool {
            assert(entry.stage == .free);
            assert(path.len > 0);
            const b = self.bus orelse return false;

            const request_id = self.next_request_id;
            self.next_request_id +%= 1;

            // Build route_prefetch CALL args (same as route CALL).
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

            if (!self.send_call(b, "route_prefetch", args_buf[0..pos], request_id, self.entry_index(entry))) {
                return false;
            }

            entry.stage = .route_prefetch_pending;
            entry.request_id = request_id;
            entry.connection = connection;
            return true;
        }

        /// Start a 1-RT request: send combined handle_render CALL.
        /// The server has already routed and executed prefetch SQL.
        /// rows_data contains serialized row sets from prefetch.
        pub fn start_combined_request(
            self: *Self,
            entry: *Entry,
            operation: message.Operation,
            msg: message.Message,
            body: []const u8,
            rows_data: []const u8,
            row_set_count: u8,
            connection: *anyopaque,
        ) bool {
            assert(entry.stage == .free);
            assert(operation != .root);
            const b = self.bus orelse return false;

            const request_id = self.next_request_id;
            self.next_request_id +%= 1;
            const entry_idx = self.entry_index(entry);

            const slot_buf = b.get_slot_request_buf(entry_idx) orelse return false;
            const frame_len = build_handle_render_frame(slot_buf, request_id, operation, msg.id, body, rows_data, row_set_count);
            b.finalize_slot_send(entry_idx, @intCast(frame_len));

            entry.stage = .combined_pending;
            entry.request_id = request_id;
            entry.operation = operation;
            entry.msg = msg;
            entry.connection = connection;
            entry.sequence = self.next_sequence;
            self.next_sequence +%= 1;
            entry.is_mutation = operation.is_mutation();
            if (entry.is_mutation) {
                self.pending_mutation_count += 1;
                if (entry.sequence < self.lowest_pending_mutation_seq) {
                    self.lowest_pending_mutation_seq = entry.sequence;
                }
            }
            return true;
        }

        /// Process a received frame — route to entry by request_id.
        pub fn on_frame(self: *Self, frame: []const u8) void {
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
                // Clean up mutation tracking before reset.
                if (entry.is_mutation) {
                    switch (entry.stage) {
                        .combined_pending, .combined_complete,
                        .write_pending,
                        .route_prefetch_pending, .route_prefetch_complete => {
                            assert(self.pending_mutation_count > 0);
                            self.pending_mutation_count -= 1;
                            self.recompute_lowest_pending_mutation();
                        },
                        else => {},
                    }
                }
                entry.reset();
                return;
            }

            // Copy result data into entry's stage-specific buffer.
            switch (entry.stage) {
                .combined_pending => {
                    // Combined RESULT: [status_len:2 BE][status][session_action:1][write_count:1][writes...][html...]
                    self.parse_combined_result(entry, result.data);
                },
                .route_prefetch_pending => {
                    // 2-RT: route+prefetch RESULT contains route info + SQL declarations.
                    self.parse_route_prefetch_result(entry, result.data);
                },
                else => {
                    log.warn("dispatch: RESULT in unexpected stage {s}", .{@tagName(entry.stage)});
                },
            }

            // Advance the pipeline after processing.
            self.advance();
        }

        /// Advance all entries that can progress. Called after on_frame
        /// and after write commits. Loops until no more progress (TB's
        /// bounded loop pattern — max iterations = entries × stages).
        pub fn advance(self: *Self) void {
            // Re-entrancy guard.
            if (self.dispatch_entered) return;
            self.dispatch_entered = true;
            defer {
                self.dispatch_entered = false;
                self.invariants();
            }

            const max_iterations: u32 = @as(u32, max_entries) * 4; // entries × stages
            var iteration: usize = 0;
            var progress = true;

            while (progress and iteration < max_iterations) : (iteration += 1) {
                progress = false;

            for (&self.entries) |*entry| {
                const prev_stage = entry.stage;
                switch (entry.stage) {
                    .combined_complete => {
                        entry.stage = .write_pending;
                    },
                    // route_prefetch_complete is handled by server's
                    // process_shm_completions which executes the SQL,
                    // then sends the handle_render CALL.
                    .route_prefetch_complete => {},
                    .write_complete => {
                        // HTML stored in handle_buf — copy to render_buf
                        // now that writes are done.
                        if (entry.html_len > 0) {
                            const hl = entry.html_len;
                            const ho = entry.html_offset;
                            // Pair assertion: parse_combined_result wrote
                            // these offsets, verify they're in bounds.
                            assert(ho + hl <= entry.handle_buf.len);
                            assert(hl <= self.render_buf.len);
                            @memcpy(self.render_buf[0..hl], entry.handle_buf[ho..][0..hl]);
                            entry.html = self.render_buf[0..hl];
                        } else {
                            entry.html = "";
                        }
                        entry.stage = .render_complete;
                    },
                    else => {},
                }
                if (entry.stage != prev_stage) progress = true;
            }
            } // while
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

        pub fn count_active(self: *const Self) u32 {
            var n: u32 = 0;
            for (&self.entries) |*entry| {
                if (entry.stage != .free) n += 1;
            }
            return n;
        }

        pub fn any_pending(self: *const Self) bool {
            for (&self.entries) |*entry| {
                switch (entry.stage) {
                    .combined_pending, .route_prefetch_pending => return true,
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
                // route_prefetch_pending has operation=.root until the
                // sidecar responds with the actual operation.
                assert(entry.operation != .root or entry.stage == .route_prefetch_pending);

                // Buffer bounds: html offsets within handle_buf.
                assert(entry.html_offset + entry.html_len <= entry.handle_buf.len);
                assert(entry.route_len <= entry.route_buf.len);

                // Mutation tracking consistency.
                if (entry.is_mutation) {
                    switch (entry.stage) {
                        .combined_pending, .combined_complete,
                        .write_pending,
                        .route_prefetch_pending, .route_prefetch_complete => {
                            mutations_pending += 1;
                        },
                        else => {},
                    }
                }
            }

            assert(active_count <= max_entries);
            assert(self.pending_mutation_count == mutations_pending);

            // Watermark consistency: if mutations are pending, the lowest
            // pending seq must be from an actual active mutation entry.
            if (self.pending_mutation_count > 0) {
                assert(self.lowest_pending_mutation_seq < std.math.maxInt(u32));
            }
            // No active entry can be in a stage that doesn't exist.
            // (Covered by the exhaustive switch in mutation tracking above.)
        }

        // =============================================================
        // Frame sending — direct to bus, no SidecarClient
        // =============================================================

        pub fn send_call(self: *Self, b: *Bus, function_name: []const u8, args: []const u8, request_id: u32, entry_idx: u8) bool {
            assert(function_name.len > 0);
            assert(entry_idx < max_entries);
            if (!b.is_connection_ready(self.connection_index)) {
                log.warn("send_call: connection {d} not ready for {s}", .{ self.connection_index, function_name });
                return false;
            }
            if (!b.can_send_to(self.connection_index)) {
                log.warn("send_call: send queue full for {s}", .{function_name});
                return false;
            }

            const msg = b.get_message();
            // Pin message to the entry's SHM slot (1:1 mapping).
            if (@hasField(Bus.Message, "slot_index")) {
                msg.slot_index = entry_idx;
            }
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

        /// Build a handle_render CALL frame directly into the SHM slot buffer.
        /// Returns the total frame length.
        fn build_handle_render_frame(
            buf: []u8,
            request_id: u32,
            operation: message.Operation,
            id: u128,
            body: []const u8,
            rows_data: []const u8,
            row_set_count: u8,
        ) usize {
            const func_name = "handle_render";
            var pos: usize = 0;

            // CALL header: [tag:1][request_id:4 BE][name_len:2 BE][name]
            buf[pos] = 0x10;
            pos += 1;
            std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
            pos += 4;
            std.mem.writeInt(u16, buf[pos..][0..2], func_name.len, .big);
            pos += 2;
            @memcpy(buf[pos..][0..func_name.len], func_name);
            pos += func_name.len;

            // Args: [operation:1][id:16 LE][body_len:2 BE][body][row_set_count:1][rows...]
            buf[pos] = @intFromEnum(operation);
            pos += 1;
            std.mem.writeInt(u128, buf[pos..][0..16], id, .little);
            pos += 16;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(body.len), .big);
            pos += 2;
            if (body.len > 0) {
                @memcpy(buf[pos..][0..body.len], body);
                pos += body.len;
            }
            buf[pos] = row_set_count;
            pos += 1;
            if (rows_data.len > 0) {
                @memcpy(buf[pos..][0..rows_data.len], rows_data);
                pos += rows_data.len;
            }

            assert(pos <= buf.len);
            return pos;
        }

        // =============================================================
        // RESULT parsers
        // =============================================================

        /// Parse combined handle+render RESULT.
        /// Format: [status_len:2 BE][status][session_action:1][write_count:1][writes...][html to end]
        fn parse_combined_result(_: *Self, entry: *Entry, data: []const u8) void {
            // Stage precondition: only called for combined_pending entries.
            assert(entry.stage == .combined_pending);

            if (data.len < 4) {
                entry.handle_status = .storage_error;
                entry.stage = .combined_complete;
                return;
            }

            var pos: usize = 0;
            const status_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + status_len + 2 > data.len) {
                entry.handle_status = .storage_error;
                entry.stage = .combined_complete;
                return;
            }
            assert(pos + status_len <= data.len);

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
            assert(pos <= data.len);

            // Skip past writes to find HTML start.
            if (entry.handle_write_count > 0) {
                // Copy writes into handle_buf for later execution.
                const writes_start = pos;
                const write_data = data[writes_start..];
                var wpos: usize = 0;
                for (0..entry.handle_write_count) |_| {
                    if (wpos + 2 > write_data.len) break;
                    const sql_len = std.mem.readInt(u16, write_data[wpos..][0..2], .big);
                    wpos += 2;
                    if (wpos + sql_len > write_data.len) break;
                    wpos += sql_len;
                    if (wpos >= write_data.len) break;
                    const param_count = write_data[wpos];
                    wpos += 1;
                    wpos = @import("protocol.zig").skip_params(write_data, wpos, param_count) orelse break;
                }
                const writes_len = wpos;
                assert(writes_len <= write_data.len);
                const copy_len = @min(writes_len, entry.handle_buf.len);
                @memcpy(entry.handle_buf[0..copy_len], write_data[0..copy_len]);
                entry.handle_writes = entry.handle_buf[0..copy_len];
                pos += writes_len;
            } else {
                entry.handle_writes = "";
            }

            // HTML is the remainder. Store in handle_buf after the writes
            // data — we can't use shared render_buf yet because writes
            // haven't executed. Copy to render_buf later in process_shm_completions.
            const html_data = data[pos..];
            const html_len = @min(html_data.len, entry.handle_buf.len - @min(entry.handle_writes.len, entry.handle_buf.len));
            const html_start = if (entry.handle_write_count > 0) entry.handle_writes.len else 0;
            if (html_start + html_len <= entry.handle_buf.len) {
                @memcpy(entry.handle_buf[html_start..][0..html_len], html_data[0..html_len]);
            }
            entry.html_offset = html_start;
            entry.html_len = html_len;

            // Pair assertion: advance will read html_offset + html_len
            // to copy HTML to render_buf. Verify bounds now at write time.
            assert(html_start + html_len <= entry.handle_buf.len);

            entry.stage = .combined_complete;
        }

        /// Parse 2-RT route+prefetch RESULT.
        /// Format: [operation:1][id:16 LE][body_len:2 BE][body]
        ///   [query_count:1][queries: [mode:1][sql_len:2 BE][sql][param_count:1][params...]]
        ///   [key_count:1][keys: [key_len:1][key_bytes][mode:1]]
        /// Stores the raw result data for the server to parse and execute SQL.
        fn parse_route_prefetch_result(self: *Self, entry: *Entry, data: []const u8) void {
            // Stage precondition.
            assert(entry.stage == .route_prefetch_pending);

            if (data.len < 20) {
                entry.reset();
                return;
            }

            var pos: usize = 0;
            const op = std.meta.intToEnum(message.Operation, data[pos]) catch {
                entry.reset();
                return;
            };
            pos += 1;
            if (op == .root) {
                entry.reset();
                return;
            }

            entry.operation = op;
            entry.msg = std.mem.zeroes(message.Message);
            entry.msg.operation = op;
            entry.msg.id = std.mem.readInt(u128, data[pos..][0..16], .little);
            pos += 16;
            assert(pos == 17); // 1 op + 16 id

            const body_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + body_len > data.len) {
                entry.reset();
                return;
            }
            assert(pos + body_len <= data.len);

            if (body_len > 0 and body_len <= message.body_max) {
                @memcpy(entry.msg.body[0..body_len], data[pos..][0..body_len]);
                entry.body_len = @intCast(body_len);
            }
            pos += body_len;

            // Store remaining (SQL declarations + keys) in route_buf.
            const remaining = data[pos..];
            const copy_len = @min(remaining.len, entry.route_buf.len);
            @memcpy(entry.route_buf[0..copy_len], remaining[0..copy_len]);
            entry.route_len = copy_len;
            assert(entry.route_len <= entry.route_buf.len);

            entry.sequence = self.next_sequence;
            self.next_sequence +%= 1;
            entry.is_mutation = op.is_mutation();
            if (entry.is_mutation) {
                self.pending_mutation_count += 1;
                if (entry.sequence < self.lowest_pending_mutation_seq) {
                    self.lowest_pending_mutation_seq = entry.sequence;
                }
            }

            entry.stage = .route_prefetch_complete;
        }

        // =============================================================
        // Internal helpers
        // =============================================================

        /// Compute entry index from pointer — entry's position in the
        /// entries array. Used to pin SHM slots 1:1 to dispatch entries.
        pub fn entry_index(self: *const Self, entry: *const Entry) u8 {
            const base = @intFromPtr(&self.entries);
            const ptr = @intFromPtr(entry);
            assert(ptr >= base);
            const idx = (ptr - base) / @sizeOf(Entry);
            assert(idx < max_entries);
            return @intCast(idx);
        }

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
                    .combined_pending, .combined_complete,
                    .write_pending,
                    .route_prefetch_pending, .route_prefetch_complete => {
                        if (entry.sequence < lowest) lowest = entry.sequence;
                    },
                    else => {},
                }
            }
            self.lowest_pending_mutation_seq = lowest;
        }
    };
}
