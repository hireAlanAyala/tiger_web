const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const http = @import("http.zig");
const ConnectionType = @import("connection.zig").ConnectionType;
const Time = @import("time.zig").Time;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.server));
const WalType = @import("wal.zig").WalType;

/// The server orchestrator, parameterized on the App, IO, and Storage types.
/// In production, IO is the real epoll-based implementation and Storage is SqliteStorage.
/// In simulation, IO is SimIO and Storage is SqliteStorage(:memory:).
///
/// App provides the domain types and functions:
///   Types: Message, Operation, Status
///   Functions: translate, encode_response, HandlersType
///   Type constructors: StateMachineType(Storage), Wal
///
/// This is the equivalent of TigerBeetle's Replica — it owns all connections,
/// drives the tick loop, and mediates between network IO and the state machine.
pub fn ServerType(comptime App: type, comptime IO: type, comptime Storage: type) type {
    comptime {
        // Validate App declarations — good errors at the boundary, not inside the guts.
        assert(@hasDecl(App, "Message"));
        assert(@hasDecl(App, "StateMachineType"));
        assert(@hasDecl(App, "Wal"));
        assert(@hasDecl(App, "translate"));
        assert(@hasDecl(App, "encode_response"));

        // Framework contracts on App types.
        // Status must have .ok — framework uses it for control flow (render vs close).
        assert(@hasField(App.Status, "ok"));
        // Message must have .operation field and .set_credential method.
        assert(@hasField(App.Message, "operation"));
        assert(@hasDecl(App.Message, "set_credential"));
        // Operation must have .is_mutation() — framework uses it for WAL decisions.
        assert(@hasDecl(App.Operation, "is_mutation"));
    }

    const Connection = ConnectionType(IO);
    const StateMachine = App.StateMachineType(Storage);
    const Wal = App.Wal;

    // Sidecar types — resolved at comptime from App.
    const SidecarClient = if (@hasDecl(App, "SidecarClientType"))
        App.SidecarClientType(IO)
    else
        void;
    const SidecarBus = if (SidecarClient != void) SidecarClient.BusType else void;

    comptime {
        // Validate StateMachine interface — framework calls these in the tick loop.
        assert(@hasDecl(StateMachine, "set_time"));
        assert(@hasDecl(StateMachine, "begin_batch"));
        assert(@hasDecl(StateMachine, "commit_batch"));
        assert(@hasDecl(StateMachine, "prefetch"));
        assert(@hasDecl(StateMachine, "commit"));
        assert(@hasField(StateMachine, "tracer"));
        assert(@hasField(StateMachine, "secret_key"));
        assert(@hasField(StateMachine, "now"));
    }

    return struct {
        const Server = @This();

        pub const max_connections = 128;

        comptime {
            assert(max_connections <= std.math.maxInt(u32));
        }

        io: *IO,
        state_machine: *StateMachine,
        time: Time,

        listen_fd: IO.fd_t,
        accept_completion: IO.Completion,
        accept_connection: ?*Connection,

        connections: []Connection,
        connections_used: u32,

        wal: ?*Wal,
        /// Assembly scratch — used by wal.append_writes to build the entry
        /// (header + writes) before writing to disk.
        wal_scratch: [@import("wal.zig").entry_max]u8 = undefined,
        /// Recording scratch — WriteView records SQL writes here during commit.
        /// Separate from wal_scratch to avoid aliasing in append_writes.
        wal_record_scratch: [@import("wal.zig").entry_max]u8 = undefined,

        tick_count: u32,
        commit_stage: CommitStage = .idle,
        /// Which connection is currently in the pipeline.
        commit_connection: ?*Connection = null,
        /// The message being processed — stored across ticks for async.
        commit_msg: ?App.Message = null,
        /// Pipeline response from handle stage — persists to render stage.
        commit_pipeline_resp: ?StateMachine.PipelineResponse = null,
        /// Prefetch cache — persists from prefetch to render.
        commit_cache: ?App.HandlersType(Storage).Cache = null,
        /// Auth identity — persists from prefetch to render.
        commit_identity: ?StateMachine.CommitOutput.Identity = null,
        /// Re-entrancy guard for commit_dispatch (TB pattern).
        /// Prevents nested execution if on_frame fires during dispatch.
        commit_dispatch_entered: bool = false,

        // --- Sidecar (optional) ---
        // Present when App.sidecar_mode is true. The server owns the bus
        // and client. Handlers have zero sidecar knowledge — the server
        // short-circuits commit_dispatch in sidecar mode.
        sidecar_client: if (SidecarClient != void) SidecarClient else void =
            if (SidecarClient != void) undefined else {},
        sidecar_bus: if (SidecarBus != void) SidecarBus else void =
            if (SidecarBus != void) undefined else {},

        /// Pipeline stage — serial, one request at a time (TB pattern).
        /// Guards process_inbox: if not .idle, no new pipeline starts.
        /// For Zig handlers, all stages complete in one tick (immediate).
        /// For sidecar handlers, stages may span ticks (async in Phase 4).
        const CommitStage = enum {
            idle,              // No request in pipeline
            route,             // Resolve raw HTTP to typed Message
            prefetch,          // SM prefetch (native handlers)
            handle,            // SM commit + writes in transaction
            render,            // Render HTML + encode response
            // Sidecar pipeline stages (server owns IO):
            // TODO: delete in Step 3 — replaced by async handler interface
            sidecar_route,
            sidecar_prefetch,
            sidecar_handle,
            sidecar_render,
        };

        /// Log metrics every 10,000 ticks (~100s at 10ms/tick).
        const metrics_interval_ticks = 10_000;

        /// 30 seconds at 10ms/tick.
        pub const request_timeout_ticks = 3000;

        /// Initialize the server. Allocates the connection pool on the heap.
        pub fn init(allocator: std.mem.Allocator, io: *IO, state_machine: *StateMachine, listen_fd: IO.fd_t, time: Time, wal: ?*Wal) !Server {
            const connections = try allocator.alloc(Connection, max_connections);
            errdefer allocator.free(connections);

            for (connections) |*conn| {
                conn.* = Connection.init_free();
            }

            return Server{
                .io = io,
                .state_machine = state_machine,
                .time = time,
                .listen_fd = listen_fd,
                .accept_completion = .{},
                .accept_connection = null,
                .connections = connections,
                .connections_used = 0,
                .wal = wal,
                .tick_count = 0,
            };
        }

        pub fn deinit(server: *Server, allocator: std.mem.Allocator) void {
            for (server.connections) |*conn| {
                if (conn.fd > 0) {
                    server.io.close(conn.fd);
                }
            }
            allocator.free(server.connections);
            if (SidecarBus != void and App.sidecar_mode) {
                server.sidecar_bus.deinit(allocator);
            }
            server.* = undefined;
        }

        /// Initialize sidecar bus and client. Called by main after server init.
        pub fn init_sidecar(server: *Server, allocator: std.mem.Allocator, path: []const u8) !void {
            if (SidecarClient == void) return;
            server.sidecar_client = SidecarClient.init();
            try server.sidecar_bus.init_listener(
                allocator,
                server.io,
                path,
                @ptrCast(server),
                sidecar_on_frame,
                sidecar_on_close,
            );
        }

        // --- Sidecar bus callbacks ---

        fn sidecar_on_frame(ctx: *anyopaque, frame: []const u8) void {
            const server: *Server = @ptrCast(@alignCast(ctx));
            if (SidecarClient == void) return;

            const query_fn = App.HandlersType(Storage).query_dispatch_fn;
            const query_ctx: *anyopaque = @ptrCast(server.state_machine.storage);
            server.sidecar_client.on_frame(
                &server.sidecar_bus,
                frame,
                query_fn,
                query_ctx,
                SidecarClient.max_queries_per_call,
            );

            // Resume pipeline if exchange completed or failed.
            switch (server.sidecar_client.call_state) {
                .complete, .failed => server.commit_dispatch(),
                .receiving => {}, // QUERY sub-protocol — more frames expected
                .idle => unreachable,
            }
        }

        fn sidecar_on_close(ctx: *anyopaque) void {
            const server: *Server = @ptrCast(@alignCast(ctx));
            if (SidecarClient == void) return;

            server.sidecar_client.on_close();

            // If a pipeline stage was waiting on sidecar, fail it.
            switch (server.commit_stage) {
                .sidecar_route, .sidecar_prefetch, .sidecar_handle, .sidecar_render => {
                    server.pipeline_reset();
                },
                else => {},
            }
        }

        /// One tick of the server. Called from the main event loop.
        ///
        /// 1. Accept new connections if slots available
        /// 2. Process inbox: execute ready requests
        /// 3. Process follow-ups: dashboard refresh after SSE mutations
        /// 4. Flush outbox: start sending responses
        /// 5. Continue receiving on connections that need more bytes
        /// 6. Close dead connections
        pub fn tick(server: *Server) void {
            server.tick_count +%= 1;
            defer server.invariants();
            // Sidecar bus: accept sidecar connections.
            if (SidecarBus != void and App.sidecar_mode) {
                server.sidecar_bus.tick_accept();
            }
            server.maybe_accept();
            server.process_inbox();
            server.log_metrics();
            server.flush_outbox();
            server.continue_receives();
            server.update_activity();
            server.timeout_idle();
            server.close_dead();
        }

        // --- Accept ---

        fn maybe_accept(server: *Server) void {
            if (server.accept_connection != null) return;

            // All slots may be busy under load.
            if (server.connections_used == server.connections.len) return;

            server.accept_connection = for (server.connections) |*conn| {
                if (conn.state == .free) {
                    conn.set_accepting();
                    break conn;
                }
            } else unreachable;

            server.io.accept(
                server.listen_fd,
                &server.accept_completion,
                @ptrCast(server),
                accept_callback,
            );
        }

        fn accept_callback(ctx: *anyopaque, result: i32) void {
            const server: *Server = @ptrCast(@alignCast(ctx));

            assert(server.accept_connection != null);
            const conn = server.accept_connection.?;
            server.accept_connection = null;

            assert(conn.fd == 0);
            assert(conn.state == .accepting);
            defer assert(conn.state == .receiving or conn.state == .free);

            // Accept may fail due to resource exhaustion or client abort.
            stdx.maybe(result < 0);
            if (result < 0) {
                log.mark.warn("accept failed: result={d}", .{result});
                conn.on_accept_error();
                return;
            }

            conn.on_accept(server.io, result, server.tick_count);
            server.connections_used += 1;
            log.debug("accepted connection fd={d}", .{result});
        }

        // --- Inbox: process ready requests ---

        fn process_inbox(server: *Server) void {
            // Set wall-clock time — only when no pipeline is in-flight.
            // A pending pipeline uses the time from when the request arrived,
            // not when it resumes. Same as TB: time is per-prepare, not per-tick.
            if (server.commit_stage == .idle) {
                server.state_machine.set_time(server.time.realtime());
            }

            // Transaction boundary moved to commit_dispatch (.handle stage).
            // WAL recording enabled there too. process_inbox only does
            // routing + pipeline start.

            for (server.connections) |*conn| {
                if (conn.state != .ready) continue;

                // Serial pipeline: one request at a time.
                // If a pipeline is in-flight, don't start another.
                if (server.commit_stage != .idle) break;

                // Re-parse HTTP from recv_buf. Deterministic — same bytes, same result.
                const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                    .complete => |p| p,
                    // Frame was validated by connection, re-parse must succeed.
                    .incomplete, .invalid => unreachable,
                };

                conn.is_datastar_request = parsed.is_datastar_request;

                // Start pipeline at .route — routing is the first stage.
                // commit_dispatch handles translate + advance to prefetch.
                server.commit_stage = .route;
                server.commit_connection = conn;
                server.commit_dispatch();
            }
        }

        /// Pipeline state machine — drives prefetch → handle → render.
        /// Called from process_inbox (start) and process_sidecar (resume).
        /// TB's commit_dispatch pattern.
        ///
        /// Each stage either completes (advance to next) or pends (return).
        /// For Zig handlers, all stages complete in one call — the loop
        /// runs start to finish. For sidecar handlers, a stage may pend
        /// waiting for a CALL RESULT. process_sidecar resumes.
        fn commit_dispatch(server: *Server) void {
            // Re-entrancy guard (TB pattern). Prevents nested execution
            // if sidecar_on_frame fires during dispatch (e.g., send_now
            // fast path completes inline and triggers a recv callback).
            assert(!server.commit_dispatch_entered);
            server.commit_dispatch_entered = true;
            defer server.commit_dispatch_entered = false;

            const sm = server.state_machine;
            const conn = server.commit_connection orelse return;

            while (true) {
                switch (server.commit_stage) {
                    .idle => return,

                    .route => {
                        // Route: resolve raw HTTP to typed Message.
                        // Re-parse from conn.recv_buf (deterministic).
                        const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                            .complete => |p| p,
                            .incomplete, .invalid => unreachable,
                        };

                        var msg = App.translate(parsed.method, parsed.path, parsed.body) orelse {
                            log.mark.warn("unmapped request: {s} {s} fd={d}", .{ @tagName(parsed.method), parsed.path, conn.fd });
                            const resp = unmapped_response(conn);
                            conn.set_response(resp.offset, resp.len);
                            conn.keep_alive = false;
                            server.pipeline_reset();
                            return;
                        };
                        msg.set_credential(parsed.identity_cookie);

                        server.commit_msg = msg;
                        server.commit_stage = .prefetch;
                        sm.tracer.start(.prefetch);
                        continue;
                    },

                    .prefetch => {
                        const msg = server.commit_msg.?;
                        switch (sm.prefetch(msg)) {
                            .complete => {
                                sm.tracer.stop(.prefetch, msg.operation);
                                sm.tracer.start(.execute);
                                server.commit_stage = .handle;
                                continue;
                            },
                            .busy => {
                                sm.tracer.cancel(.prefetch);
                                server.pipeline_reset();
                                return;
                            },
                            .pending => {
                                // Handler needs async IO — callback will
                                // call commit_dispatch to resume.
                                return;
                            },
                        }
                    },

                    .handle => {
                        const msg = server.commit_msg.?;
                        assert(sm.prefetch_cache != null);
                        // Invariant: handle result not yet produced.
                        assert(server.commit_pipeline_resp == null);

                        // Commit: handle writes inside a transaction.
                        sm.begin_batch();

                        if (server.wal != null) {
                            sm.wal_record_buf = &server.wal_record_scratch;
                        }

                        const commit_output = sm.commit(msg);
                        server.commit_pipeline_resp = commit_output.response;
                        server.commit_cache = commit_output.cache;
                        server.commit_identity = commit_output.identity;

                        // WAL: log SQL writes.
                        if (server.wal) |wal| {
                            if (!wal.disabled and msg.operation.is_mutation()) {
                                wal.append_writes(
                                    msg.operation,
                                    sm.now,
                                    if (sm.wal_record_buf) |buf| buf[0..sm.wal_record_len] else "",
                                    sm.wal_record_count,
                                    &server.wal_scratch,
                                );
                                sm.wal_record_len = 0;
                                sm.wal_record_count = 0;
                            }
                        }

                        sm.commit_batch();

                        server.commit_stage = .render;
                        continue;
                    },


                    .render => {
                        const msg = server.commit_msg.?;
                        assert(server.commit_pipeline_resp != null);
                        assert(server.commit_cache != null);
                        assert(server.commit_identity != null);

                        const pipeline_resp = server.commit_pipeline_resp.?;
                        const cache = server.commit_cache.?;
                        const identity = server.commit_identity.?;

                        const FwCtx = App.HandlersType(Storage).FwCtx;
                        const fw = FwCtx{
                            .identity = identity,
                            .now = sm.now,
                            .is_sse = conn.is_datastar_request,
                        };

                        const ro = Storage.ReadView.init(sm.storage);
                        const html = App.HandlersType(Storage).handler_render(
                            cache,
                            msg.operation,
                            pipeline_resp.status,
                            fw,
                            &App.render_scratch_buf,
                            ro,
                        );

                        server.encode_and_respond(conn, msg, pipeline_resp, html);
                        return;
                    },

                    // =========================================================
                    // Sidecar pipeline stages
                    // Server owns all IO. Handlers are not called.
                    // Each stage: send CALL → wait for RESULT → process.
                    // on_frame callback resumes commit_dispatch.
                    // =========================================================

                    .sidecar_route => {
                        if (SidecarClient == void) unreachable;
                        const client = &server.sidecar_client;

                        switch (client.call_state) {
                            .idle => {
                                // First call: build route args and send CALL.
                                const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                                    .complete => |p| p,
                                    .incomplete, .invalid => unreachable,
                                };
                                // [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
                                var args: [1 + 2 + 0xFFFF + 2 + 0xFFFF]u8 = undefined;
                                var pos: usize = 0;
                                args[pos] = @intFromEnum(parsed.method);
                                pos += 1;
                                std.mem.writeInt(u16, args[pos..][0..2], @intCast(parsed.path.len), .big);
                                pos += 2;
                                @memcpy(args[pos..][0..parsed.path.len], parsed.path);
                                pos += parsed.path.len;
                                const body = parsed.body;
                                std.mem.writeInt(u16, args[pos..][0..2], @intCast(body.len), .big);
                                pos += 2;
                                @memcpy(args[pos..][0..body.len], body);
                                pos += body.len;

                                client.reset_call_state();
                                if (!client.call_submit(&server.sidecar_bus, "route", args[0..pos])) {
                                    server.pipeline_reset();
                                    return;
                                }
                                return; // pending — on_frame resumes
                            },
                            .receiving => return, // still waiting
                            .complete => {
                                // Parse RESULT: [found: u8][operation: u8][id: u128 BE]
                                defer client.reset_call_state();
                                if (client.result_flag == .failure) {
                                    server.pipeline_reset();
                                    return;
                                }
                                const data = client.result_data;
                                if (data.len < 1 or data[0] == 0 or data.len < 18) {
                                    // Not found or malformed.
                                    const resp = unmapped_response(conn);
                                    conn.set_response(resp.offset, resp.len);
                                    conn.keep_alive = false;
                                    server.pipeline_reset();
                                    return;
                                }
                                const operation = std.meta.intToEnum(App.Operation, data[1]) catch {
                                    server.pipeline_reset();
                                    return;
                                };
                                const id = std.mem.readInt(u128, data[2..18], .big);

                                var route_msg = std.mem.zeroes(App.Message);
                                route_msg.operation = operation;
                                route_msg.id = id;

                                // Re-parse for credential.
                                const parsed2 = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                                    .complete => |p| p,
                                    .incomplete, .invalid => unreachable,
                                };
                                route_msg.set_credential(parsed2.identity_cookie);

                                server.commit_msg = route_msg;
                                server.commit_stage = .sidecar_prefetch;
                                continue;
                            },
                            .failed => {
                                client.reset_call_state();
                                server.pipeline_reset();
                                return;
                            },
                        }
                    },

                    .sidecar_prefetch => {
                        if (SidecarClient == void) unreachable;
                        const client = &server.sidecar_client;

                        switch (client.call_state) {
                            .idle => {
                                // Resolve auth before prefetch (same as SM.prefetch).
                                sm.resolve_credential(server.commit_msg.?);

                                // Build args: [operation: u8][id: u128 BE]
                                const m = server.commit_msg.?;
                                var args: [1 + 16]u8 = undefined;
                                args[0] = @intFromEnum(m.operation);
                                std.mem.writeInt(u128, args[1..17], m.id, .big);

                                if (!client.call_submit(&server.sidecar_bus, "prefetch", &args)) {
                                    server.pipeline_reset();
                                    return;
                                }
                                return; // pending
                            },
                            .receiving => return,
                            .complete => {
                                defer client.reset_call_state();
                                if (client.result_flag == .failure) {
                                    server.pipeline_reset();
                                    return;
                                }
                                // Prefetch complete — advance to handle.
                                server.commit_stage = .sidecar_handle;
                                continue;
                            },
                            .failed => {
                                client.reset_call_state();
                                server.pipeline_reset();
                                return;
                            },
                        }
                    },

                    .sidecar_handle => {
                        if (SidecarClient == void) unreachable;
                        const client = &server.sidecar_client;

                        switch (client.call_state) {
                            .idle => {
                                // Send CALL — no transaction yet. Transaction
                                // opens when RESULT arrives and we execute writes
                                // synchronously. TB pattern: don't open a transaction
                                // across async boundaries.
                                const m = server.commit_msg.?;
                                var args: [1 + 16]u8 = undefined;
                                args[0] = @intFromEnum(m.operation);
                                std.mem.writeInt(u128, args[1..17], m.id, .big);

                                if (!client.call_submit(&server.sidecar_bus, "handle", &args)) {
                                    server.pipeline_reset();
                                    return;
                                }
                                return; // pending
                            },
                            .receiving => return,
                            .complete => {
                                defer client.reset_call_state();

                                if (client.result_flag == .failure) {
                                    server.pipeline_reset();
                                    return;
                                }

                                const data = client.result_data;

                                // Parse: [status_len: u16 BE][status_str][write_count: u8][writes...]
                                if (data.len < 3) {
                                    server.pipeline_reset();
                                    return;
                                }
                                const status_len = std.mem.readInt(u16, data[0..2], .big);
                                if (2 + status_len + 1 > data.len) {
                                    server.pipeline_reset();
                                    return;
                                }
                                const status_str = data[2..][0..status_len];
                                const write_count = data[2 + status_len];
                                const write_data = data[2 + status_len + 1 ..];

                                // Transaction: open, execute writes, WAL, close.
                                // All synchronous — no async boundary inside transaction.
                                sm.begin_batch();
                                if (server.wal != null) {
                                    sm.wal_record_buf = &server.wal_record_scratch;
                                }

                                client.handle_writes = write_data;
                                client.handle_write_count = write_count;
                                var write_view = if (sm.wal_record_buf) |buf|
                                    Storage.WriteView.init_recording(sm.storage, buf)
                                else
                                    Storage.WriteView.init(sm.storage);
                                if (!client.execute_writes(&write_view)) {
                                    client.handle_writes = "";
                                    client.handle_write_count = 0;
                                    sm.commit_batch();
                                    server.pipeline_reset();
                                    return;
                                }
                                sm.wal_record_len = write_view.record_pos;
                                sm.wal_record_count = write_view.record_count;
                                client.handle_writes = "";
                                client.handle_write_count = 0;

                                // WAL.
                                const m = server.commit_msg.?;
                                if (server.wal) |wal| {
                                    if (!wal.disabled and m.operation.is_mutation()) {
                                        wal.append_writes(
                                            m.operation,
                                            sm.now,
                                            if (sm.wal_record_buf) |buf| buf[0..sm.wal_record_len] else "",
                                            sm.wal_record_count,
                                            &server.wal_scratch,
                                        );
                                        sm.wal_record_len = 0;
                                        sm.wal_record_count = 0;
                                    }
                                }

                                sm.commit_batch();

                                const status = App.Status.from_string(status_str) orelse .storage_error;
                                const identity = sm.prefetch_identity orelse std.mem.zeroes(StateMachine.CommitOutput.Identity);

                                server.commit_pipeline_resp = .{
                                    .status = status,
                                    .session_action = .none,
                                    .user_id = identity.user_id,
                                    .is_authenticated = identity.is_authenticated != 0,
                                    .is_new_visitor = identity.is_new != 0,
                                };

                                server.commit_stage = .sidecar_render;
                                continue;
                            },
                            .failed => {
                                client.reset_call_state();
                                server.pipeline_reset();
                                return;
                            },
                        }
                    },

                    .sidecar_render => {
                        if (SidecarClient == void) unreachable;
                        const client = &server.sidecar_client;

                        switch (client.call_state) {
                            .idle => {
                                const m = server.commit_msg.?;
                                const pipeline_resp = server.commit_pipeline_resp.?;
                                const args = [_]u8{
                                    @intFromEnum(m.operation),
                                    @intFromEnum(pipeline_resp.status),
                                };

                                if (!client.call_submit(&server.sidecar_bus, "render", &args)) {
                                    server.pipeline_reset();
                                    return;
                                }
                                return; // pending
                            },
                            .receiving => return,
                            .complete => {
                                defer client.reset_call_state();
                                const pipeline_resp = server.commit_pipeline_resp.?;

                                const html = if (client.result_flag == .failure)
                                    @as([]const u8, "")
                                else
                                    client.copy_state(client.result_data);

                                server.encode_and_respond(conn, server.commit_msg.?, pipeline_resp, html);
                                return;
                            },
                            .failed => {
                                client.reset_call_state();
                                server.pipeline_reset();
                                return;
                            },
                        }
                    },
                }
            }
        }

        /// Encode response and send to client. Shared by native render
        /// and sidecar render stages.
        fn encode_and_respond(
            server: *Server,
            conn: *Connection,
            msg: App.Message,
            pipeline_resp: StateMachine.PipelineResponse,
            html: []const u8,
        ) void {
            const sm = server.state_machine;
            const commit_result = App.encode_response(
                pipeline_resp.status,
                html,
                &conn.send_buf,
                conn.is_datastar_request,
                pipeline_resp.session_action,
                pipeline_resp.user_id,
                pipeline_resp.is_authenticated,
                pipeline_resp.is_new_visitor,
                sm.secret_key,
            );

            sm.tracer.stop(.execute, msg.operation);
            sm.tracer.trace_log(msg.operation, commit_result.status, conn.fd);

            conn.set_response(commit_result.response.offset, commit_result.response.len);
            conn.keep_alive = commit_result.response.keep_alive;

            server.pipeline_reset();
        }

        /// Register sidecar fd for readability notification via epoll.
        /// Called when a sidecar CALL is in-flight (.pending).
        /// Reset the pipeline to idle. Called on completion, busy, or failure.
        fn pipeline_reset(server: *Server) void {
            server.commit_stage = .idle;
            server.commit_connection = null;
            server.commit_msg = null;
            server.commit_pipeline_resp = null;
            server.commit_cache = null;
            server.commit_identity = null;
        }

        fn log_metrics(server: *Server) void {
            if (server.tick_count % metrics_interval_ticks != 0) return;

            // Push connection pool gauges into tracer.
            var connections_active: u32 = 0;
            var connections_receiving: u32 = 0;
            var connections_ready: u32 = 0;
            var connections_sending: u32 = 0;
            for (server.connections) |*conn| {
                if (conn.state == .free) continue;
                connections_active += 1;
                switch (conn.state) {
                    .receiving => connections_receiving += 1,
                    .ready => connections_ready += 1,
                    .sending => connections_sending += 1,
                    .accepting, .closing, .free => {},
                }
            }
            server.state_machine.tracer.gauge(.connections_active, connections_active);
            server.state_machine.tracer.gauge(.connections_receiving, connections_receiving);
            server.state_machine.tracer.gauge(.connections_ready, connections_ready);
            server.state_machine.tracer.gauge(.connections_sending, connections_sending);

            _ = server.state_machine.tracer.emit();
        }

        // --- Outbox: send pending responses ---

        fn flush_outbox(server: *Server) void {
            for (server.connections) |*conn| {
                if (conn.state != .sending) continue;
                // Don't re-submit if a send is already in-flight.
                if (conn.send_completion.operation != .none) continue;
                if (conn.send_pos < conn.send_len) {
                    conn.submit_send(server.io);
                }
            }
        }

        // --- Continue receiving on connections that need more bytes ---

        fn continue_receives(server: *Server) void {
            for (server.connections) |*conn| {
                if (conn.state == .free) continue;
                conn.continue_recv(server.io);
            }
        }

        // --- Close dead connections ---

        fn close_dead(server: *Server) void {
            for (server.connections) |*conn| {
                if (conn.state != .closing) continue;
                assert(conn.fd > 0);

                log.debug("closing connection fd={d}", .{conn.fd});
                server.io.close(conn.fd);
                conn.* = Connection.init_free();
                server.connections_used -= 1;
            }
        }

        // --- Activity tracking ---

        /// Update last_activity_tick for connections that signaled activity via callbacks.
        fn update_activity(server: *Server) void {
            for (server.connections) |*conn| {
                if (conn.state == .free) continue;
                if (conn.recv_activity or conn.send_activity) {
                    conn.last_activity_tick = server.tick_count;
                    conn.recv_activity = false;
                    conn.send_activity = false;
                }
            }
        }

        // --- Timeout idle connections ---

        fn timeout_idle(server: *Server) void {
            for (server.connections) |*conn| {
                if (conn.state == .free or conn.state == .accepting or conn.state == .closing) continue;
                if (conn.check_timeout(server.tick_count, request_timeout_ticks)) {
                    log.mark.debug("connection timed out fd={d}", .{conn.fd});
                    conn.state = .closing;
                }
            }
        }

        /// Write a short error response for requests that parsed as valid HTTP
        /// but couldn't be routed (unknown path, malformed JSON, bad UUID, etc.).
        fn unmapped_response(conn: *Connection) struct { offset: u32, len: u32 } {
            const response =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 16\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "invalid request\n";
            @memcpy(conn.send_buf[0..response.len], response);
            return .{ .offset = 0, .len = response.len };
        }

        /// Cross-check structural invariants after every tick.
        /// Connection-level invariants are checked by Connection.invariants().
        fn invariants(server: *Server) void {
            var accepting_count: u32 = 0;
            var active_count: u32 = 0;

            for (server.connections) |*conn| {
                conn.invariants();

                if (conn.state == .accepting) {
                    accepting_count += 1;
                } else if (conn.state != .free) {
                    active_count += 1;
                }
            }

            // connections_used counts active connections (not accepting).
            assert(server.connections_used == active_count);

            // At most one connection can be in accepting state.
            assert(accepting_count <= 1);
            if (server.accept_connection != null) {
                assert(accepting_count == 1);
            }
        }
    };
}
