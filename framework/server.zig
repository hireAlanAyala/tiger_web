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
///   Type constructors: StateMachineType(Storage, IO), Wal
///
/// This is the equivalent of TigerBeetle's Replica — it owns all connections,
/// drives the tick loop, and mediates between network IO and the state machine.
pub fn ServerType(comptime App: type, comptime IO: type, comptime Storage: type) type {
    comptime {
        // Validate App declarations — good errors at the boundary, not inside the guts.
        assert(@hasDecl(App, "Message"));
        assert(@hasDecl(App, "HandlersFor"));
        assert(@hasDecl(App, "StateMachineWith"));
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
    // Resolved Handlers — native or sidecar, selected at comptime.
    // The server resolves Handlers (which needs IO for sidecar),
    // then constructs the SM from Handlers. SM never sees IO.
    const Handlers = App.HandlersFor(Storage, IO);
    const StateMachine = App.StateMachineWith(Storage, Handlers);
    const Wal = App.Wal;

    // Sidecar types — resolved from Handlers at comptime.
    // Bus and Client are embedded in the Server struct (TB pattern:
    // Replica embeds MessageBus). Callbacks recover Server via
    // the context pointer set during init.
    const SidecarBus = if (App.sidecar_enabled) Handlers.BusType else void;
    const SidecarClient = if (App.sidecar_enabled) Handlers.ClientType else void;

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

        /// Pipeline stage — serial, one request at a time (TB pattern).
        /// Guards process_inbox: if not .idle, no new pipeline starts.
        /// For Zig handlers, all stages complete in one tick (immediate).
        /// For sidecar handlers, stages may span ticks (async via bus callbacks).
        const CommitStage = enum {
            idle,              // No request in pipeline
            route,             // Resolve raw HTTP to typed Message
            prefetch,          // SM prefetch (native handlers)
            handle,            // SM commit + writes in transaction
            render,            // Render HTML + encode response
        };

        /// Log metrics every 10,000 ticks (~100s at 10ms/tick).
        const metrics_interval_ticks = 10_000;

        /// 30 seconds at 10ms/tick.
        pub const request_timeout_ticks = 3000;

        // --- Fields ---

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
        commit_cache: ?Handlers.Cache = null,
        /// Auth identity — persists from prefetch to render.
        commit_identity: ?StateMachine.CommitOutput.Identity = null,
        /// Re-entrancy guard for commit_dispatch (TB pattern).
        /// Prevents nested execution if on_frame fires during dispatch.
        commit_dispatch_entered: bool = false,

        // Sidecar Bus and Client — embedded in the Server (TB pattern:
        // Replica embeds MessageBus). Callbacks use the context pointer
        // set during init to recover the Server. Comptime-eliminated
        // when sidecar_enabled = false (void fields, zero bytes).
        sidecar_bus: SidecarBus = if (App.sidecar_enabled) undefined else {},
        sidecar_client: SidecarClient = if (App.sidecar_enabled) undefined else {},

        /// Binary sidecar state: connected (handshake complete) or not.
        /// All request routing checks this field. No partial states,
        /// no retries. Present or absent.
        sidecar_connected: bool = false,
        /// Sidecar process ID — from READY handshake. Used for
        /// SIGKILL on protocol violations.
        sidecar_pid: u32 = 0,

        /// Initialize the server. Allocates the connection pool on the heap.
        /// When sidecar_enabled, also initializes the embedded Bus and Client,
        /// wires them into sm.handlers, and starts listening on the socket path.
        /// TB pattern: Replica.init creates the MessageBus last, after all
        /// other state is ready.
        pub fn init(
            allocator: std.mem.Allocator,
            io: *IO,
            state_machine: *StateMachine,
            listen_fd: IO.fd_t,
            time: Time,
            wal: ?*Wal,
        ) !Server {
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

        /// Wire the sidecar Bus and Client into the server and SM.
        /// Called AFTER the server is stored at its final address
        /// (caller's stack or heap). Takes &self — pointers to
        /// embedded fields are stable because self won't move.
        ///
        /// Two-phase init: Server.init returns the struct, then
        /// wire_sidecar takes addresses of the embedded fields.
        /// This avoids dangling pointers from return-by-value.
        pub fn wire_sidecar(server: *Server, allocator: std.mem.Allocator, sidecar_path: ?[]const u8) !void {
            if (!App.sidecar_enabled) return;
            server.sidecar_client = SidecarClient.init();
            try server.sidecar_bus.init_pool(
                allocator,
                server.io,
                @ptrCast(server),
                sidecar_on_frame,
                sidecar_on_close,
            );
            server.state_machine.handlers.sidecar_client = &server.sidecar_client;
            server.state_machine.handlers.sidecar_bus = &server.sidecar_bus;
            if (sidecar_path) |path| {
                server.sidecar_bus.start_listener(path);
            }
        }

        pub fn deinit(server: *Server, allocator: std.mem.Allocator) void {
            for (server.connections) |*conn| {
                if (conn.fd > 0) {
                    server.io.close(conn.fd);
                }
            }
            allocator.free(server.connections);
            server.* = undefined;
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
            // Ordering constraint: sidecar bus tick_accept runs BEFORE
            // process_inbox. process_inbox calls commit_dispatch (sets
            // commit_dispatch_entered = true). sidecar_on_frame also
            // calls commit_dispatch. If tick_accept ran during or after
            // process_inbox, a bus recv callback could fire while
            // commit_dispatch_entered is true → assertion failure.
            // tick_accept only accepts new connections — it never
            // delivers frames (that happens in IO.run_for_ns, which
            // runs after tick returns). This ordering is safe.
            if (App.sidecar_enabled) server.sidecar_bus.tick_accept();
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

                // Start pipeline at .route — routing is the first stage.
                // commit_dispatch parses HTTP and routes.
                server.commit_stage = .route;
                server.commit_connection = conn;
                server.commit_dispatch();
            }
        }

        /// Pipeline state machine — drives route → prefetch → handle → render.
        /// Called from process_inbox (start). When a handler returns .pending,
        /// the async callback calls commit_dispatch to resume.
        /// TB's commit_dispatch pattern.
        ///
        /// Each stage either completes (advance to next) or pends (return).
        /// For native handlers, all stages complete in one call. For async
        /// handlers (Phase 2), a stage may return .pending.
        fn commit_dispatch(server: *Server) void {
            // Re-entrancy guard (TB pattern). Currently no async callbacks
            // (native handlers are sync). Phase 2 adds async handler callbacks
            // that call commit_dispatch to resume — the guard prevents nested
            // execution.
            assert(!server.commit_dispatch_entered);
            server.commit_dispatch_entered = true;
            defer server.commit_dispatch_entered = false;

            const sm = server.state_machine;
            const conn = server.commit_connection orelse return;

            // Bounded loop (TB pattern). 4 stages × 2 for safety.
            // Each iteration advances commit_stage forward. If we ever
            // loop more than 8 times, a bug caused a backward jump or
            // infinite cycle — crash immediately.
            for (0..8) |_| {
                switch (server.commit_stage) {
                    .idle => return,

                    .route => {
                        // Sidecar not connected → 503 immediately.
                        // No retries. Binary state: present or absent.
                        if (App.sidecar_enabled and !server.sidecar_connected) {
                            const resp = sidecar_unavailable_response(conn);
                            conn.set_response(resp.offset, resp.len);
                            conn.keep_alive = false;
                            server.pipeline_reset();
                            return;
                        }

                        // Route: parse HTTP and resolve to typed Message.
                        const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                            .complete => |p| p,
                            .incomplete, .invalid => unreachable,
                        };
                        conn.is_datastar_request = parsed.is_datastar_request;

                        var msg = sm.handlers.handler_route(parsed.method, parsed.path, parsed.body) orelse {
                            // Sidecar: handler_route returns null while pending.
                            // Native: null means unmapped request.
                            if (sm.handlers.is_handler_pending()) return;
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
                                // Sidecar disconnected or storage busy.
                                // Reset pipeline — the HTTP connection stays
                                // in .ready. Next tick, process_inbox picks
                                // it up and re-routes from scratch. This
                                // retries every 10ms until the sidecar
                                // reconnects or the HTTP connection times out
                                // (30s). Re-routing is stateless (parses the
                                // same recv_buf), so repeated retries are safe.
                                //
                                // Optimization opportunity: stay in .prefetch
                                // and retry without re-routing. Not needed for
                                // correctness — the route result is deterministic.
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
                        assert(server.commit_identity != null);

                        const pipeline_resp = server.commit_pipeline_resp.?;
                        const cache = server.commit_cache.?;
                        const identity = server.commit_identity.?;

                        const fw = Handlers.FwCtx{
                            .identity = identity,
                            .now = sm.now,
                            .is_sse = conn.is_datastar_request,
                        };

                        const ro = Storage.ReadView.init(sm.storage);
                        const html = sm.handlers.handler_render(
                            cache,
                            msg.operation,
                            pipeline_resp.status,
                            fw,
                            &App.render_scratch_buf,
                            ro,
                        ) orelse return; // pending — sidecar render in-flight

                        server.encode_and_respond(conn, msg, pipeline_resp, html);
                        return;
                    },

                }
            } else unreachable; // loop bound exceeded — pipeline bug
        }

        /// Encode response and send to client.
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

        /// Reset the pipeline to idle. Called on completion, busy, or failure.
        /// NOTE: callers are responsible for stopping/cancelling their own
        /// tracer spans before calling pipeline_reset. The .busy branch
        /// cancels .prefetch, the .render stage stops .execute, etc.
        fn pipeline_reset(server: *Server) void {
            server.state_machine.handlers.reset_handler_state();
            server.commit_stage = .idle;
            server.commit_connection = null;
            server.commit_msg = null;
            server.commit_pipeline_resp = null;
            server.commit_cache = null;
            server.commit_identity = null;
        }

        // =============================================================
        // Sidecar bus callbacks — only compiled when sidecar_enabled.
        //
        // The bus delivers frames via on_frame_fn. The server processes
        // them through the sidecar client, then resumes the pipeline
        // if the CALL completed.
        //
        // Callback chain:
        //   bus.on_frame → sidecar_on_frame → client.on_frame
        //     → if .complete → commit_dispatch (resume pipeline)
        // =============================================================

        /// Called by the sidecar bus when a frame is received.
        /// Two modes:
        /// - Before handshake: expects READY frame. Validates version
        ///   and stores PID. Sets sidecar_connected = true.
        /// - After handshake: routes to sidecar client (CALL/RESULT).
        pub fn sidecar_on_frame(ctx: *anyopaque, frame: []const u8) void {
            if (!App.sidecar_enabled) unreachable;
            const server: *Server = @ptrCast(@alignCast(ctx));

            if (!server.sidecar_connected) {
                // Handshake: expect READY frame.
                const protocol = @import("../protocol.zig");
                const ready = protocol.parse_ready_frame(frame) orelse {
                    log.warn("sidecar: invalid READY frame, killing", .{});
                    server.kill_sidecar();
                    return;
                };
                if (ready.version != protocol.protocol_version) {
                    log.warn("sidecar: version mismatch: expected {d}, got {d}", .{
                        protocol.protocol_version, ready.version,
                    });
                    server.kill_sidecar();
                    return;
                }
                server.sidecar_pid = ready.pid;
                server.sidecar_connected = true;
                log.info("sidecar: connected (pid={d}, version={d})", .{
                    ready.pid, ready.version,
                });
                return;
            }

            // Normal operation: route to sidecar client.
            server.state_machine.handlers.process_sidecar_frame(frame, server.state_machine.storage);

            // Protocol violation → kill sidecar immediately.
            if (App.sidecar_enabled) {
                const c = server.state_machine.handlers.sidecar_client orelse unreachable;
                if (c.protocol_violation) {
                    log.warn("sidecar: protocol violation detected, killing", .{});
                    server.kill_sidecar();
                    return;
                }
            }

            // Resume pipeline if the CALL completed (or failed).
            if (server.commit_stage != .idle and !server.state_machine.handlers.is_handler_pending()) {
                server.commit_dispatch();
            }
        }

        /// Called when the sidecar bus connection closes.
        pub fn sidecar_on_close(ctx: *anyopaque) void {
            if (!App.sidecar_enabled) unreachable;
            const server: *Server = @ptrCast(@alignCast(ctx));
            server.sidecar_connected = false;
            server.sidecar_pid = 0;
            log.info("sidecar: disconnected", .{});

            server.state_machine.handlers.on_sidecar_close();

            if (server.commit_stage == .render) {
                // Render crash: writes already committed. Send
                // minimal response — never retry pipeline.
                server.render_crash_fallback();
                return;
            }

            if (server.commit_stage != .idle) {
                // Pre-handle crash: full pipeline reset is safe.
                const sm = server.state_machine;
                switch (server.commit_stage) {
                    .route => {},
                    .prefetch => sm.tracer.cancel(.prefetch),
                    .render => unreachable, // handled above
                    .handle, .idle => {},
                }
                server.pipeline_reset();
            } else {
                server.state_machine.handlers.reset_handler_state();
            }
        }

        /// Kill the sidecar process — SIGKILL, not SIGTERM.
        /// Called on protocol violations (corrupt frame, version
        /// mismatch, request_id mismatch). The hypervisor restarts it.
        fn kill_sidecar(server: *Server) void {
            if (!App.sidecar_enabled) unreachable;
            if (server.sidecar_pid != 0) {
                log.warn("sidecar: killing pid={d}", .{server.sidecar_pid});
                std.posix.kill(@intCast(server.sidecar_pid), std.posix.SIG.KILL) catch |err| {
                    log.warn("sidecar: kill failed: {}", .{err});
                };
            }
            // Terminate the bus connection — on_close will fire,
            // which sets sidecar_connected = false.
            if (server.sidecar_bus.connection.state == .connected) {
                server.sidecar_bus.connection.terminate(.shutdown);
            }
        }

        /// Render crash fallback — writes committed, sidecar gone.
        /// Send a minimal response using committed pipeline data.
        /// Never retry — retrying re-executes handle → duplicate writes.
        fn render_crash_fallback(server: *Server) void {
            const conn = server.commit_connection orelse {
                server.pipeline_reset();
                return;
            };
            const msg = server.commit_msg.?;
            const pipeline_resp = server.commit_pipeline_resp.?;

            // Minimal response: operation succeeded, render degraded.
            const fallback_html = "<html><body>Operation completed. Refresh for full page.</body></html>";
            server.encode_and_respond(conn, msg, pipeline_resp, fallback_html);
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
                    // If this connection has a pending pipeline, cancel it
                    // before closing. Otherwise the pipeline resumes on a
                    // closing connection — use-after-close.
                    if (server.commit_connection == conn and server.commit_stage != .idle) {
                        const sm = server.state_machine;
                        switch (server.commit_stage) {
                            .route => {}, // no tracer span active during route
                            .prefetch => sm.tracer.cancel(.prefetch),
                            .render => sm.tracer.cancel(.execute),
                            .handle, .idle => {},
                        }
                        server.pipeline_reset();
                    }
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

        /// 503-equivalent: sidecar not connected. Distinct from
        /// unmapped (404-like). Connection: close — client should retry.
        fn sidecar_unavailable_response(conn: *Connection) struct { offset: u32, len: u32 } {
            const response =
                "HTTP/1.1 503 Service Unavailable\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 24\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "service unavailable\n";
            @memcpy(conn.send_buf[0..response.len], response);
            return .{ .offset = 0, .len = response.len };
        }

        /// Cross-check structural invariants after every tick.
        /// Connection-level invariants are checked by Connection.invariants().
        /// Handler-level invariants checked by sm.handlers.invariants().
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

            // Handler invariants — cross-checks prefetch_phase vs call_state.
            server.state_machine.handlers.invariants();
        }
    };
}
