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
const log = std.log.scoped(.sidecar_handlers);

pub fn SidecarHandlersType(comptime StorageParam: type, comptime Bus: type) type {
    const SidecarClient = @import("sidecar.zig").SidecarClientType(Bus);

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
        // Two lifetime groups, structurally separated:
        //   infra   — set once during wire_sidecar, never reset
        //   request — per-request state, reset via request = .{}
        //
        // New per-request fields go in Request. New infrastructure
        // fields go at the top level. If a per-request field is added
        // at the top level, reset_handler_state won't clear it —
        // stale state leaks between requests silently.
        // =============================================================

        /// Infrastructure — set during wire_sidecar, lives for server lifetime.
        /// Optional until wired. Every handler method unwraps with .? —
        /// panics on null instead of UB from undefined.
        sidecar_client: ?*SidecarClient = null,
        sidecar_bus: ?*Bus = null,
        /// Paired bus connection index — each handler sends to its own connection.
        connection_index: u8 = 0,

        /// Per-request state — reset on each pipeline_reset via request = .{}.
        /// Adding a field to Request without a default produces a compile error
        /// in reset_handler_state. Total by construction.
        request: Request = .{},

        const Request = struct {
            prefetch_phase: PrefetchPhase = .idle,
            /// Handle result — parsed from handle CALL RESULT.
            handle_status: message.Status = .ok,
            handle_session_action: message.SessionAction = .none,
            /// Monotonic request ID — incremented per CALL for correlation.
            next_request_id: u32 = 1,
        };

        // =============================================================
        // Handler interface — instance methods matching HandlersType.
        // =============================================================

        /// Whether a sidecar CALL is in-flight.
        pub fn is_handler_pending(self: *const Self) bool {
            const c = self.sidecar_client orelse return false; // not wired yet
            return c.call_state == .receiving;
        }

        /// Reset per-request handler state. Infrastructure (client, bus,
        /// connection_index) is untouched. request = .{} is total by
        /// construction — can't miss a field when new ones are added.
        pub fn reset_handler_state(self: *Self) void {
            if (self.sidecar_client) |c| {
                c.reset_call_state();
                c.reset_request_state();
            }
            self.request = .{};
        }

        /// Route: CALL "route" with HTTP method/path/body.
        /// First call: submit CALL, return null (pending).
        /// Resume: parse RESULT into Message.
        ///
        /// Args format: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
        /// Result format: [operation: u8][id: 16 bytes LE][body: N bytes]
        pub fn handler_route(self: *Self, method_val: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
            assert(self.request.prefetch_phase == .idle);
            const c = self.sidecar_client.?;
            const b = self.sidecar_bus.?;

            switch (c.call_state) {
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

                    if (!c.call_submit(b, self.connection_index, "route", args_buf[0..pos], self.request.next_request_id)) {
                        return null;
                    }
                    self.request.next_request_id +%= 1;
                    return null; // pending
                },
                .receiving => return null,
                .complete => {
                    c.log_call_timing("route");
                    defer c.reset_call_state();
                    if (c.result_flag != .success) return null;
                    return parse_route_result(c.result_data);
                },
                .failed => {
                    c.reset_call_state();
                    return null;
                },
            }
        }

        /// Prefetch: multi-call sequence.
        ///   Phase 1: CALL "prefetch" — sidecar runs handler.prefetch(db)
        ///   Phase 2: CALL "handle"   — sidecar runs handler.handle(db)
        /// Returns null while pending. Returns void cache when complete.
        pub fn handler_prefetch(self: *Self, storage: *StorageParam, msg: *const message.Message) ?Cache {
            _ = storage;
            const c = self.sidecar_client.?;

            switch (c.call_state) {
                .idle => {
                    if (self.request.prefetch_phase == .idle) {
                        if (!self.submit_operation_call("prefetch", msg)) return null;
                        self.request.prefetch_phase = .prefetch_pending;
                        return null;
                    }
                    if (self.request.prefetch_phase == .prefetch_pending) {
                        if (!self.submit_operation_call("handle", msg)) {
                            self.request.prefetch_phase = .idle;
                            return null;
                        }
                        self.request.prefetch_phase = .handle_pending;
                        return null;
                    }
                    unreachable;
                },
                .receiving => return null,
                .complete => {
                    if (self.request.prefetch_phase == .prefetch_pending) {
                        c.log_call_timing("prefetch");
                        c.reset_call_state();
                        if (!self.submit_operation_call("handle", msg)) {
                            self.request.prefetch_phase = .idle;
                            return null;
                        }
                        self.request.prefetch_phase = .handle_pending;
                        return null;
                    }
                    if (self.request.prefetch_phase == .handle_pending) {
                        c.log_call_timing("handle");
                        self.parse_handle_result();
                        c.reset_call_state();
                        self.request.prefetch_phase = .idle;
                        return {};
                    }
                    unreachable;
                },
                .failed => {
                    c.reset_call_state();
                    self.request.prefetch_phase = .idle;
                    return null;
                },
            }
        }

        pub fn handler_execute(
            self: *Self,
            cache: Cache,
            msg: message.Message,
            fw: FwCtx,
            db: anytype,
        ) state_machine.HandleResult {
            assert(self.request.prefetch_phase == .idle);
            _ = cache;
            _ = msg;
            _ = fw;
            const c = self.sidecar_client.?;

            if (!c.execute_writes(db)) {
                return .{ .status = .storage_error };
            }

            return .{
                .status = self.request.handle_status,
                .session_action = self.request.handle_session_action,
            };
        }

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
            const c = self.sidecar_client.?;
            const b = self.sidecar_bus.?;

            switch (c.call_state) {
                .idle => {
                    var args_buf: [2]u8 = undefined;
                    args_buf[0] = @intFromEnum(operation);
                    args_buf[1] = @intFromEnum(status);

                    if (!c.call_submit(b, self.connection_index, "render", &args_buf, self.request.next_request_id)) {
                        return render_error(render_buf);
                    }
                    self.request.next_request_id +%= 1;
                    return null;
                },
                .receiving => return null,
                .complete => {
                    c.log_call_timing("render");
                    defer c.reset_call_state();
                    if (c.result_flag != .success) {
                        return render_error(render_buf);
                    }
                    const html = c.result_data;
                    if (html.len > render_buf.len) {
                        log.warn("render: HTML too large ({d} > {d})", .{ html.len, render_buf.len });
                        return render_error(render_buf);
                    }
                    @memcpy(render_buf[0..html.len], html);
                    return render_buf[0..html.len];
                },
                .failed => {
                    c.reset_call_state();
                    return render_error(render_buf);
                },
            }
        }

        /// QUERY dispatch — wraps StorageParam.query_raw.
        pub fn query_dispatch_fn(ctx: *anyopaque, sql: []const u8, params_buf: []const u8, param_count: u8, mode: protocol.QueryMode, out_buf: []u8) ?[]const u8 {
            const s: *StorageParam = @ptrCast(@alignCast(ctx));
            const ro = StorageParam.ReadView.init(s);
            return ro.query_raw(sql, params_buf, param_count, mode, out_buf);
        }

        /// Process a frame received from the sidecar bus.
        /// Re-entrancy note: called from bus's try_drain_recv loop.
        /// Send and recv state are independent. slot.dispatch_entered
        /// guards against nested pipeline execution.
        pub fn process_sidecar_frame(self: *Self, frame: []const u8, storage: *StorageParam) void {
            const c = self.sidecar_client.?;
            const b = self.sidecar_bus.?;
            c.on_frame(b, self.connection_index, frame, query_dispatch_fn, @ptrCast(storage), SidecarClient.max_queries_per_call);
        }

        /// Called when the sidecar bus connection closes.
        pub fn on_sidecar_close(self: *Self) void {
            const c = self.sidecar_client.?;
            c.on_close();
        }

        /// Cross-check structural invariants.
        pub fn invariants(self: *const Self) void {
            const c = self.sidecar_client orelse return; // not wired yet
            const cs = c.call_state;
            switch (self.request.prefetch_phase) {
                .idle => {
                    if (cs == .idle) {
                        assert(self.request.handle_status == .ok);
                        assert(self.request.handle_session_action == .none);
                    }
                },
                .prefetch_pending => {
                    assert(cs == .receiving or cs == .complete or cs == .failed);
                },
                .handle_pending => {
                    assert(cs == .receiving or cs == .complete or cs == .failed);
                },
            }
        }

        // =============================================================
        // Private helpers
        // =============================================================

        fn submit_operation_call(self: *Self, function_name: []const u8, msg: *const message.Message) bool {
            const c = self.sidecar_client.?;
            const b = self.sidecar_bus.?;
            var args_buf: [17]u8 = undefined;
            args_buf[0] = @intFromEnum(msg.operation);
            std.mem.writeInt(u128, args_buf[1..17], msg.id, .little);
            if (!c.call_submit(b, self.connection_index, function_name, &args_buf, self.request.next_request_id)) {
                return false;
            }
            self.request.next_request_id +%= 1;
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
            const c = self.sidecar_client.?;
            const data = c.result_data;

            // Minimum: status_name_len(2) + session_action(1) + write_count(1) = 4.
            // Status name can be 0 bytes (empty name → from_string fails → error).
            if (data.len < 4) {
                log.warn("handle: RESULT too short ({d} bytes)", .{data.len});
                self.request.handle_status = .storage_error;
                return;
            }

            var pos: usize = 0;

            // Status name (u16 BE length-prefixed string → enum).
            const status_name_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + status_name_len + 2 > data.len) {
                // +2 for the mandatory session_action + write_count after status name.
                log.warn("handle: RESULT truncated at status name", .{});
                self.request.handle_status = .storage_error;
                return;
            }
            const status_name = data[pos..][0..status_name_len];
            pos += status_name_len;
            self.request.handle_status = message.Status.from_string(status_name) orelse {
                log.warn("handle: unknown status '{s}'", .{status_name});
                self.request.handle_status = .storage_error;
                return;
            };

            // Session action — reject unknown values. Field is mandatory.
            self.request.handle_session_action = switch (data[pos]) {
                0 => .none,
                1 => .set_authenticated,
                2 => .clear,
                else => {
                    log.warn("handle: unknown session_action {d}", .{data[pos]});
                    self.request.handle_status = .storage_error;
                    return;
                },
            };
            pos += 1;

            // Write count — mandatory. Write data follows.
            c.handle_write_count = data[pos];
            pos += 1;
            if (c.handle_write_count > 0 and pos >= data.len) {
                log.warn("handle: write_count={d} but no write data", .{c.handle_write_count});
                self.request.handle_status = .storage_error;
                return;
            }
            // data is already in state_buf (copied by on_frame's
            // copy_state). No need to copy again — the slice is
            // stable and owned. Avoids wasting state_buf capacity.
            c.handle_writes = if (pos < data.len)
                data[pos..]
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
