//! Sidecar handler dispatch — CALL/RESULT protocol over message bus.
//!
//! Implements the same Handlers interface as HandlersType (native).
//! Delegates routing, prefetch, handle, and render to an external
//! sidecar runtime via the CALL/RESULT protocol.
//!
//! The pipeline:
//!   Route:    CALL "route" → Message                     (async)
//!   Prefetch: CALL "prefetch" → CALL "handle" → cache    (async, multi-call)
//!   Execute:  parse handle RESULT, apply writes           (sync — always)
//!   Render:   CALL "render" → HTML                       (async)
//!
//! Execute is permanently synchronous. The handle CALL happens during
//! prefetch so all data is loaded before execute opens a transaction.
//! See state_machine.zig commit() doc comment.
//!
//! All state lives in struct fields — inspectable by invariants().
//! The SM holds `handlers: Handlers` as a field. For native handlers,
//! this is zero-size. For sidecar, it holds client/bus pointers and
//! protocol phase state.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const state_machine = @import("state_machine.zig");
const http = @import("framework/http.zig");
const message_bus = @import("framework/message_bus.zig");

const log = std.log.scoped(.sidecar_handlers);

pub fn SidecarHandlersType(comptime StorageParam: type, comptime IO: type) type {
    const SidecarClient = @import("sidecar.zig").SidecarClientType(IO);
    const bus_options: message_bus.Options = .{ .send_queue_max = 2, .frame_max = protocol.frame_max };
    const Bus = message_bus.MessageBusType(IO, bus_options);

    return struct {
        const Self = @This();

        /// Sidecar cache — data lives in SidecarClient.state_buf, not here.
        pub const Cache = void;

        pub const FwCtx = @import("framework/handler.zig").FrameworkCtx(message.PrefetchIdentity);

        /// Exposed types for init — main.zig needs these to create
        /// the client and bus before constructing the Handlers struct.
        pub const ClientType = SidecarClient;
        pub const BusType = Bus;

        /// Sub-phase for multi-call prefetch sequence.
        /// The prefetch stage sequences two CALLs:
        ///   1. CALL "prefetch" — sidecar runs handler.prefetch()
        ///   2. CALL "handle"   — sidecar runs handler.handle()
        /// Each is async. The phase tracks where we are.
        const PrefetchPhase = enum {
            idle,
            prefetch_pending,
            handle_pending,
        };

        // =============================================================
        // Struct fields — all sidecar handler state lives here.
        // Inspectable by invariants(). Reset by reset_handler_state().
        // =============================================================

        sidecar_client: *SidecarClient,
        sidecar_bus: *Bus,

        prefetch_phase: PrefetchPhase = .idle,

        /// Handle result — parsed from handle CALL RESULT.
        /// Stored between prefetch completion and execute.
        /// Status and session_action live here (handler decision).
        /// Write data (handle_writes/handle_write_count) lives on the
        /// SidecarClient because copy_state uses the client's internal
        /// buffer — the writes slice points into client.state_buf.
        handle_status: message.Status = .ok,
        handle_session_action: message.SessionAction = .none,

        /// Monotonic request ID — incremented per CALL for correlation.
        /// The sidecar echoes this in RESULT. Even though serial today,
        /// the ID lets both sides detect stale responses.
        next_request_id: u32 = 1,

        // =============================================================
        // Handler interface — instance methods matching HandlersType.
        // =============================================================

        /// Whether a sidecar CALL is in-flight.
        pub fn is_handler_pending(self: *const Self) bool {
            return self.sidecar_client.call_state == .receiving;
        }

        /// Reset handler state. Called by the server on pipeline_reset.
        /// Atomic self-assignment — adding a field without a default
        /// produces a compile error here, not a silent stale-state bug.
        /// Pointer fields (sidecar_client, sidecar_bus) are preserved.
        pub fn reset_handler_state(self: *Self) void {
            self.sidecar_client.reset_call_state();
            self.sidecar_client.reset_request_state();
            self.* = .{
                .sidecar_client = self.sidecar_client,
                .sidecar_bus = self.sidecar_bus,
            };
        }

        /// Route: CALL "route" with HTTP method/path/body.
        /// First call: submit CALL, return null (pending).
        /// Resume: parse RESULT into Message.
        ///
        /// Args format: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
        /// Result format: [operation: u8][id: 16 bytes LE][body: N bytes]
        pub fn handler_route(self: *Self, method_val: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
            // Pair assertion: prefetch must not be in progress when a new
            // route starts. Catches stale state from a missed reset.
            assert(self.prefetch_phase == .idle);

            switch (self.sidecar_client.call_state) {
                .idle => {
                    // Build args: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
                    // Max size bounded by HTTP parser: path ≤ max_header_size, body ≤ body_max.
                    const args_max = 1 + 2 + http.max_header_size + 2 + http.body_max;
                    var args_buf: [args_max]u8 = undefined;
                    var pos: usize = 0;

                    args_buf[pos] = @intFromEnum(method_val);
                    pos += 1;
                    std.mem.writeInt(u16, args_buf[pos..][0..2], @intCast(raw_path.len), .big);
                    pos += 2;
                    @memcpy(args_buf[pos..][0..raw_path.len], raw_path);
                    pos += raw_path.len;
                    std.mem.writeInt(u16, args_buf[pos..][0..2], @intCast(body.len), .big);
                    pos += 2;
                    if (body.len > 0) {
                        @memcpy(args_buf[pos..][0..body.len], body);
                        pos += body.len;
                    }

                    // call_submit checks bounds via build_call before writing.
                    if (!self.sidecar_client.call_submit(self.sidecar_bus, "route", args_buf[0..pos], self.next_request_id)) {
                        return null;
                    }
                    self.next_request_id +%= 1;
                    return null; // pending
                },
                .receiving => return null, // still pending
                .complete => {
                    defer self.sidecar_client.reset_call_state();
                    if (self.sidecar_client.result_flag != .success) return null;
                    return parse_route_result(self.sidecar_client.result_data);
                },
                .failed => {
                    self.sidecar_client.reset_call_state();
                    return null;
                },
            }
        }

        /// Prefetch: multi-call sequence.
        ///   Phase 1: CALL "prefetch" — sidecar runs handler.prefetch(db)
        ///   Phase 2: CALL "handle"   — sidecar runs handler.handle(db)
        /// Returns null while pending. Returns void cache when complete.
        pub fn handler_prefetch(self: *Self, storage: *StorageParam, msg: *const message.Message) ?Cache {
            _ = storage; // Storage accessed via query_dispatch_fn during QUERY sub-protocol

            switch (self.sidecar_client.call_state) {
                .idle => {
                    if (self.prefetch_phase == .idle) {
                        if (!self.submit_operation_call("prefetch", msg)) {
                            return null;
                        }
                        self.prefetch_phase = .prefetch_pending;
                        return null; // pending
                    }
                    if (self.prefetch_phase == .prefetch_pending) {
                        // Prefetch complete, transition to handle.
                        if (!self.submit_operation_call("handle", msg)) {
                            self.prefetch_phase = .idle;
                            return null;
                        }
                        self.prefetch_phase = .handle_pending;
                        return null; // pending
                    }
                    // Invariant: handle_pending can't reach call_state == .idle
                    // without going through .complete (which resets prefetch_phase
                    // to .idle) or .failed (which also resets to .idle).
                    unreachable;
                },
                .receiving => return null, // still pending
                .complete => {
                    if (self.prefetch_phase == .prefetch_pending) {
                        // Prefetch RESULT received. The sidecar keeps its own
                        // prefetch data — the Zig side doesn't need it. Reset
                        // call_state and submit CALL "handle".
                        self.sidecar_client.reset_call_state();
                        if (!self.submit_operation_call("handle", msg)) {
                            self.prefetch_phase = .idle;
                            return null;
                        }
                        self.prefetch_phase = .handle_pending;
                        return null; // pending
                    }
                    if (self.prefetch_phase == .handle_pending) {
                        // Parse handle result — status + writes.
                        self.parse_handle_result();
                        self.sidecar_client.reset_call_state();
                        self.prefetch_phase = .idle;
                        return {}; // void cache — data in client state
                    }
                    // Same invariant as .idle branch.
                    unreachable;
                },
                .failed => {
                    self.sidecar_client.reset_call_state();
                    self.prefetch_phase = .idle;
                    return null; // busy/fail — SM retries
                },
            }
        }

        /// Execute: ALWAYS synchronous. Applies writes from handle RESULT.
        /// No sidecar IO. The handle CALL already ran during prefetch.
        pub fn handler_execute(
            self: *Self,
            cache: Cache,
            msg: message.Message,
            fw: FwCtx,
            db: anytype,
        ) state_machine.HandleResult {
            // Pair assertion: the multi-call prefetch sequence must have
            // completed before execute runs.
            assert(self.prefetch_phase == .idle);
            _ = cache;
            _ = msg;
            _ = fw;

            if (!self.sidecar_client.execute_writes(db)) {
                return .{ .status = .storage_error };
            }

            return .{
                .status = self.handle_status,
                .session_action = self.handle_session_action,
            };
        }

        /// Render: CALL "render" → HTML.
        /// Returns null when pending. Returns HTML slice when complete.
        pub fn handler_render(
            self: *Self,
            cache: Cache,
            operation: message.Operation,
            status: message.Status,
            fw: FwCtx,
            render_buf: []u8,
            storage: anytype,
        ) ?[]const u8 {
            _ = cache;
            _ = fw;
            _ = storage;

            switch (self.sidecar_client.call_state) {
                .idle => {
                    var args_buf: [2]u8 = undefined;
                    args_buf[0] = @intFromEnum(operation);
                    args_buf[1] = @intFromEnum(status);

                    if (!self.sidecar_client.call_submit(self.sidecar_bus, "render", &args_buf, self.next_request_id)) {
                        return render_error(render_buf);
                    }
                    self.next_request_id +%= 1;
                    return null; // pending
                },
                .receiving => return null,
                .complete => {
                    defer self.sidecar_client.reset_call_state();
                    if (self.sidecar_client.result_flag != .success) {
                        return render_error(render_buf);
                    }
                    const html = self.sidecar_client.result_data;
                    if (html.len > render_buf.len) {
                        log.warn("render: HTML too large ({d} > {d})", .{ html.len, render_buf.len });
                        return render_error(render_buf);
                    }
                    @memcpy(render_buf[0..html.len], html);
                    return render_buf[0..html.len];
                },
                .failed => {
                    self.sidecar_client.reset_call_state();
                    return render_error(render_buf);
                },
            }
        }

        /// QUERY dispatch function for CALL/RESULT protocol.
        /// Same as native — wraps StorageParam.query_raw.
        pub fn query_dispatch_fn(ctx: *anyopaque, sql: []const u8, params_buf: []const u8, param_count: u8, mode: protocol.QueryMode, out_buf: []u8) ?[]const u8 {
            const s: *StorageParam = @ptrCast(@alignCast(ctx));
            const ro = StorageParam.ReadView.init(s);
            return ro.query_raw(sql, params_buf, param_count, mode, out_buf);
        }

        /// Process a frame received from the sidecar bus.
        /// Called by the server's sidecar_on_frame callback.
        ///
        /// Re-entrancy note: called from inside the bus's try_drain_recv
        /// loop (via on_frame_fn). The handler may call bus.send_message
        /// (for QUERY_RESULT) which modifies the send queue — but send
        /// and recv state are independent. After return, the server may
        /// call commit_dispatch (guarded by commit_dispatch_entered).
        pub fn process_sidecar_frame(self: *Self, frame: []const u8, storage: *StorageParam) void {
            self.sidecar_client.on_frame(self.sidecar_bus, frame, query_dispatch_fn, @ptrCast(storage), SidecarClient.max_queries_per_call);
        }

        /// Called when the sidecar bus connection closes.
        /// Sets call_state to .failed if a CALL was in-flight.
        /// Does NOT reset handler state — the server's pipeline_reset
        /// (called after this) handles that via reset_handler_state().
        /// Keeping reset in one place avoids double-reset.
        pub fn on_sidecar_close(self: *Self) void {
            self.sidecar_client.on_close();
        }

        /// Cross-check structural invariants. Called by the server's
        /// invariants() via sm.handlers.invariants().
        ///
        /// Verifies the relationship between prefetch_phase (handler
        /// state) and call_state (protocol state). These are maintained
        /// by different code paths — pair assertions catch drift.
        /// Cross-check structural invariants. Called by the server's
        /// invariants() via sm.handlers.invariants().
        ///
        /// Verifies the relationship between prefetch_phase (handler
        /// state) and call_state (protocol state). These are maintained
        /// by different code paths — pair assertions catch drift.
        pub fn invariants(self: *const Self) void {
            const cs = self.sidecar_client.call_state;
            switch (self.prefetch_phase) {
                .idle => {
                    // When prefetch is idle and call_state is also idle,
                    // the full pipeline is idle — handle result must be
                    // at defaults. If call_state is non-idle, a route or
                    // render CALL may be in-flight (valid).
                    if (cs == .idle) {
                        assert(self.handle_status == .ok);
                        assert(self.handle_session_action == .none);
                    }
                },
                .prefetch_pending => {
                    // CALL "prefetch" submitted — call_state must be
                    // receiving (waiting) or complete/failed (result arrived,
                    // not yet processed by next handler_prefetch call).
                    assert(cs == .receiving or cs == .complete or cs == .failed);
                },
                .handle_pending => {
                    // CALL "handle" submitted — same valid states.
                    assert(cs == .receiving or cs == .complete or cs == .failed);
                },
            }
        }

        // =============================================================
        // Private helpers
        // =============================================================

        fn submit_operation_call(self: *Self, function_name: []const u8, msg: *const message.Message) bool {
            var args_buf: [17]u8 = undefined;
            args_buf[0] = @intFromEnum(msg.operation);
            std.mem.writeInt(u128, args_buf[1..17], msg.id, .little);
            if (!self.sidecar_client.call_submit(self.sidecar_bus, function_name, &args_buf, self.next_request_id)) {
                return false;
            }
            self.next_request_id +%= 1;
            return true;
        }

        fn parse_route_result(data: []const u8) ?message.Message {
            if (data.len < 17) return null;

            const op_byte = data[0];
            const op = std.meta.intToEnum(message.Operation, op_byte) catch return null;
            if (op == .root) return null;

            const id = std.mem.readInt(u128, data[1..17], .little);
            const body_data = data[17..];

            var msg = std.mem.zeroes(message.Message);
            msg.operation = op;
            msg.id = id;
            if (body_data.len > 0) {
                const copy_len = @min(body_data.len, message.body_max);
                @memcpy(msg.body[0..copy_len], body_data[0..copy_len]);
            }
            return msg;
        }

        /// Parse handle RESULT — strict. Every field must be present.
        /// A short or malformed frame is a protocol error, not a no-op.
        /// Format: [status_name_len: u16 BE][status_name][session_action: u8]
        ///         [write_count: u8][writes...]
        fn parse_handle_result(self: *Self) void {
            const data = self.sidecar_client.result_data;

            // Minimum: status_name_len(2) + session_action(1) + write_count(1) = 4.
            // Status name can be 0 bytes (empty name → from_string fails → error).
            if (data.len < 4) {
                log.warn("handle: RESULT too short ({d} bytes)", .{data.len});
                self.handle_status = .storage_error;
                return;
            }

            var pos: usize = 0;

            // Status name (u16 BE length-prefixed string → enum).
            const status_name_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + status_name_len + 2 > data.len) {
                // +2 for the mandatory session_action + write_count after status name.
                log.warn("handle: RESULT truncated at status name", .{});
                self.handle_status = .storage_error;
                return;
            }
            const status_name = data[pos..][0..status_name_len];
            pos += status_name_len;
            self.handle_status = message.Status.from_string(status_name) orelse {
                log.warn("handle: unknown status '{s}'", .{status_name});
                self.handle_status = .storage_error;
                return;
            };

            // Session action — reject unknown values. Field is mandatory.
            self.handle_session_action = switch (data[pos]) {
                0 => .none,
                1 => .set_authenticated,
                2 => .clear,
                else => {
                    log.warn("handle: unknown session_action {d}", .{data[pos]});
                    self.handle_status = .storage_error;
                    return;
                },
            };
            pos += 1;

            // Write count — mandatory. Write data follows.
            self.sidecar_client.handle_write_count = data[pos];
            pos += 1;
            if (self.sidecar_client.handle_write_count > 0 and pos >= data.len) {
                log.warn("handle: write_count={d} but no write data", .{self.sidecar_client.handle_write_count});
                self.handle_status = .storage_error;
                return;
            }
            self.sidecar_client.handle_writes = if (pos < data.len)
                self.sidecar_client.copy_state(data[pos..])
            else
                "";
        }

        fn render_error(render_buf: []u8) []const u8 {
            const err_html = "<div>sidecar render error</div>";
            if (err_html.len <= render_buf.len) {
                @memcpy(render_buf[0..err_html.len], err_html);
                return render_buf[0..err_html.len];
            }
            return "";
        }
    };
}
