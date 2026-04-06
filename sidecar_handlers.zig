//! Sidecar handler dispatch — 1-CALL protocol over message bus.
//!
//! Implements the same Handlers interface as HandlersType (native).
//! Delegates all user logic to an external sidecar runtime via a
//! single CALL "request" per HTTP request.
//!
//! The pipeline:
//!   Route:    CALL "request" → combined RESULT              (async)
//!   Prefetch: returns cached void (data already in RESULT)  (sync)
//!   Execute:  parse writes from RESULT, apply to SQLite     (sync)
//!   Render:   return cached HTML from RESULT                (sync)
//!
//! One CALL per request. The sidecar runs route + prefetch (QUERY
//! sub-calls for db.query) + handle + render internally. Returns
//! operation + id + status + writes + html in one RESULT frame.
//!
//! Why 1 CALL, not 4: each frame costs ~2µs (CRC32 + memcpy + epoll).
//! The old 4-CALL protocol used 10+ frames/request. At 8 sidecar slots,
//! the single-threaded event loop saturated on frame processing (30K req/s).
//! 1-CALL reduces to 4 frames/request → 36K req/s (+20%). The remaining
//! gap to Fastify (49K) is the QUERY sub-protocol round trips.
//! See docs/internal/decision-sidecar-1call-protocol.md.
//!
//! All state lives in struct fields — inspectable by invariants().

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

        // =============================================================
        // Two lifetime groups, structurally separated:
        //   infra   — set once during wire_sidecar, never reset
        //   request — per-request state, reset via request = .{}
        // =============================================================

        /// Infrastructure — set during wire_sidecar, lives for server lifetime.
        sidecar_client: ?*SidecarClient = null,
        sidecar_bus: ?*Bus = null,
        /// Paired bus connection index — each handler sends to its own connection.
        connection_index: u8 = 0,

        /// Per-request state — reset on each pipeline_reset via request = .{}.
        request: Request = .{},

        const Request = struct {
            /// Handle result — parsed from combined RESULT.
            handle_status: message.Status = .ok,
            handle_session_action: message.SessionAction = .none,
            /// Cached HTML from combined RESULT — slice into state_buf.
            cached_html: []const u8 = "",
            /// Whether the combined RESULT has been fully parsed.
            result_parsed: bool = false,
            /// Monotonic request ID — incremented per CALL for correlation.
            next_request_id: u32 = 1,
        };

        // =============================================================
        // Handler interface — instance methods matching HandlersType.
        // =============================================================

        pub fn is_handler_pending(self: *const Self) bool {
            const c = self.sidecar_client orelse return false;
            return c.call_state == .receiving;
        }

        pub fn reset_handler_state(self: *Self) void {
            if (self.sidecar_client) |c| {
                c.reset_call_state();
                c.reset_request_state();
            }
            self.request = .{};
        }

        /// Route: submit CALL "request" with full HTTP request.
        /// First call: submit CALL, return null (pending).
        /// Resume (on RESULT): parse combined result → Message.
        ///
        /// Args format: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
        /// Result format: [operation: u8][id: 16 LE][event_body_len: u16 BE][event_body]
        ///                [status_len: u16 BE][status][session_action: u8]
        ///                [write_count: u8][writes...]
        ///                [html to end]
        pub fn handler_route(self: *Self, method_val: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
            const c = self.sidecar_client.?;
            const b = self.sidecar_bus.?;

            switch (c.call_state) {
                .idle => {
                    // Build args: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
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

                    if (!c.call_submit(b, self.connection_index, "request", args_buf[0..pos], self.request.next_request_id)) {
                        return null;
                    }
                    self.request.next_request_id +%= 1;
                    return null; // pending
                },
                .receiving => return null,
                .complete => {
                    defer c.reset_call_state();
                    if (c.result_flag != .success) return null;
                    return self.parse_request_result(c.result_data);
                },
                .failed => {
                    c.reset_call_state();
                    return null;
                },
            }
        }

        /// Prefetch: returns immediately. All data was received in
        /// the combined RESULT from handler_route.
        pub fn handler_prefetch(self: *Self, storage: *StorageParam, msg: *const message.Message) ?Cache {
            _ = storage;
            _ = msg;
            // The combined RESULT is already parsed. Return void cache.
            if (self.request.result_parsed) return {};
            // Should not reach here — result_parsed is set by handler_route.
            return null;
        }

        /// Execute: apply buffered writes from the combined RESULT.
        pub fn handler_execute(
            self: *Self,
            cache: Cache,
            msg: message.Message,
            fw: FwCtx,
            db: anytype,
        ) state_machine.HandleResult {
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

        /// Render: return cached HTML from the combined RESULT.
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
            _ = operation;
            _ = status;
            _ = fw;
            _ = storage;

            const html = self.request.cached_html;
            if (html.len == 0) return "";
            if (html.len > render_buf.len) {
                log.warn("render: HTML too large ({d} > {d})", .{ html.len, render_buf.len });
                return render_error(render_buf);
            }
            @memcpy(render_buf[0..html.len], html);
            return render_buf[0..html.len];
        }

        /// Process a frame from the sidecar bus. Delegates to the
        /// SidecarClient's on_frame which handles RESULT/QUERY routing.
        pub fn process_sidecar_frame(self: *Self, frame: []const u8, storage: *StorageParam) void {
            const c = self.sidecar_client.?;
            const b = self.sidecar_bus.?;
            c.on_frame(b, self.connection_index, frame, query_fn_wrapper, @ptrCast(storage), protocol.queries_max);
        }

        fn query_fn_wrapper(ctx: *anyopaque, sql: []const u8, params_buf: []const u8, param_count: u8, mode: protocol.QueryMode, out_buf: []u8) ?[]const u8 {
            const storage: *StorageParam = @ptrCast(@alignCast(ctx));
            return storage.query_raw(sql, params_buf, param_count, mode, out_buf);
        }

        pub fn on_sidecar_close(self: *Self) void {
            if (self.sidecar_client) |c| {
                c.on_close();
            }
            self.request = .{};
        }

        pub fn query_dispatch_fn(ctx: *anyopaque, sql: []const u8, params_buf: []const u8, param_count: u8, mode: protocol.QueryMode, out_buf: []u8) ?[]const u8 {
            const s: *StorageParam = @ptrCast(@alignCast(ctx));
            const ro = StorageParam.ReadView.init(s);
            return ro.query_raw(sql, params_buf, param_count, mode, out_buf);
        }

        pub fn invariants(self: *const Self) void {
            const c = self.sidecar_client orelse return;
            _ = c;
            // With 1-CALL protocol, idle state means no pending result.
            if (!self.request.result_parsed) {
                assert(self.request.handle_status == .ok);
                assert(self.request.handle_session_action == .none);
                assert(self.request.cached_html.len == 0);
            }
        }

        // =============================================================
        // Combined RESULT parser
        // =============================================================

        /// Parse the combined RESULT from CALL "request".
        /// Layout: [operation: u8][id: 16 LE][event_body_len: u16 BE][event_body]
        ///         [status_len: u16 BE][status][session_action: u8]
        ///         [write_count: u8][writes...]
        ///         [html to end]
        fn parse_request_result(self: *Self, data: []const u8) ?message.Message {
            const c = self.sidecar_client.?;

            // Minimum: operation(1) + id(16) + event_body_len(2) +
            //          status_len(2) + session_action(1) + write_count(1) = 23
            if (data.len < 23) return null;

            var pos: usize = 0;

            // --- Route fields ---
            const op_byte = data[pos];
            pos += 1;
            const op = std.meta.intToEnum(message.Operation, op_byte) catch return null;
            if (op == .root) return null;

            const id = std.mem.readInt(u128, data[pos..][0..16], .little);
            pos += 16;

            const event_body_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + event_body_len > data.len) return null;
            const event_body = data[pos..][0..event_body_len];
            pos += event_body_len;

            // --- Handle fields ---
            if (pos + 4 > data.len) return null; // status_len(2) + session_action(1) + write_count(1)

            const status_name_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
            if (pos + status_name_len + 2 > data.len) return null;
            const status_name = data[pos..][0..status_name_len];
            pos += status_name_len;

            self.request.handle_status = message.Status.from_string(status_name) orelse {
                log.warn("request: unknown status '{s}'", .{status_name});
                return null;
            };

            self.request.handle_session_action = switch (data[pos]) {
                0 => .none,
                1 => .set_authenticated,
                2 => .clear,
                else => {
                    log.warn("request: unknown session_action {d}", .{data[pos]});
                    return null;
                },
            };
            pos += 1;

            const write_count = data[pos];
            pos += 1;
            c.handle_write_count = write_count;
            c.handle_writes = if (write_count > 0 and pos < data.len)
                data[pos..]
            else
                "";

            // Skip past writes to find HTML at the end.
            if (write_count > 0) {
                var writes_pos = pos;
                for (0..write_count) |_| {
                    if (writes_pos + 2 > data.len) return null;
                    const sql_len = std.mem.readInt(u16, data[writes_pos..][0..2], .big);
                    writes_pos += 2;
                    if (writes_pos + sql_len > data.len) return null;
                    writes_pos += sql_len;
                    if (writes_pos >= data.len) return null;
                    const param_count = data[writes_pos];
                    writes_pos += 1;
                    writes_pos = SidecarClient.skip_params(data, writes_pos, param_count) orelse return null;
                }
                // Writes are in data[pos..writes_pos]. Update handle_writes to exact slice.
                c.handle_writes = data[pos..writes_pos];
                pos = writes_pos;
            }

            // --- Render fields: HTML is the remainder ---
            self.request.cached_html = if (pos < data.len) data[pos..] else "";
            self.request.result_parsed = true;

            // Build Message from route fields.
            var msg = std.mem.zeroes(message.Message);
            msg.operation = op;
            msg.id = id;
            if (event_body.len > 0) {
                const copy_len = @min(event_body.len, message.body_max);
                @memcpy(msg.body[0..copy_len], event_body[0..copy_len]);
            }
            return msg;
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
