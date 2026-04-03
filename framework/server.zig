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
    const msg_types = @import("../message.zig");
    // Resolved Handlers — native or sidecar, selected at comptime.
    // Handlers are per-slot on the server. The SM doesn't see handlers.
    const Handlers = App.HandlersFor(Storage, IO);
    const Wal = App.Wal;

    // Sidecar types — resolved from Handlers at comptime.
    // Bus and Client are embedded in the Server struct (TB pattern:
    // Replica embeds MessageBus). Callbacks recover Server via
    // the context pointer set during init.
    const SidecarBus = if (App.sidecar_enabled) Handlers.BusType else void;
    const SidecarClient = if (App.sidecar_enabled) Handlers.ClientType else void;

    // Pipeline slot count — derived from bus connections. Used for
    // SM construction (tracer per-slot spans) and Server arrays.
    const slots_max: u8 = if (App.sidecar_enabled) SidecarBus.connections_max else 1;
    const StateMachine = App.StateMachineWith(Storage, slots_max);

    comptime {
        // Validate StateMachine interface — framework services.
        assert(@hasDecl(StateMachine, "set_time"));
        assert(@hasDecl(StateMachine, "begin_batch"));
        assert(@hasDecl(StateMachine, "commit_batch"));
        assert(@hasDecl(StateMachine, "resolve_credential"));
        assert(@hasField(StateMachine, "tracer"));
        assert(@hasField(StateMachine, "secret_key"));
        assert(@hasField(StateMachine, "now"));
    }

    return struct {
        const Server = @This();

        pub const max_connections = 128;

        /// Number of pipeline slots — one per sidecar connection.
        /// Native handlers (no sidecar) use 1 slot (synchronous).
        /// Sidecar handlers use N slots (one per bus connection).
        pub const pipeline_slots_max: u8 = slots_max;

        comptime {
            assert(max_connections <= std.math.maxInt(u32));
            assert(pipeline_slots_max >= 1);
        }

        /// Pipeline stage for each slot. Stages progress forward:
        /// idle → route → prefetch → handle → render → idle.
        /// handle_wait is a stall state (waiting for handle_lock).
        /// For Zig handlers, all stages complete in one tick (immediate).
        /// For sidecar handlers, stages may span ticks (async via bus callbacks).
        const CommitStage = enum {
            idle,              // No request in pipeline
            route,             // Resolve raw HTTP to typed Message
            prefetch,          // Auth + handler data loading
            handle,            // Execute handler + writes in transaction
            handle_wait,       // Waiting for handle_lock (another slot writing)
            render,            // Render HTML + encode response
        };

        const PipelineResponse = msg_types.PipelineResponse;

        /// Pipeline slot — owns all per-request state for one in-flight pipeline.
        /// One slot per sidecar connection (pipeline_slots_max = sidecar_count).
        /// Native handlers use 1 slot (synchronous, all stages complete in one tick).
        const PipelineSlot = struct {
            stage: CommitStage = .idle,
            /// Which connection is currently in the pipeline.
            connection: ?*Connection = null,
            /// The message being processed — stored across ticks for async.
            msg: ?App.Message = null,
            /// Pipeline response from handle stage — persists to render stage.
            pipeline_resp: ?PipelineResponse = null,
            /// Prefetch cache — persists from prefetch to render.
            cache: ?Handlers.Cache = null,
            /// Auth identity — persists from prefetch to render.
            identity: ?msg_types.PrefetchIdentity = null,
            /// Re-entrancy guard for commit_dispatch (TB pattern).
            /// Prevents nested execution if on_frame fires during dispatch.
            dispatch_entered: bool = false,
            /// Tick when the pipeline started waiting for sidecar response.
            /// Used for response timeout — SIGKILL if exceeded.
            pending_since: u32 = 0,

            /// Reset pipeline state to idle. Uses struct default init —
            /// total by construction, can't miss a field when new ones are added.
            fn reset(slot: *PipelineSlot) void {
                slot.* = .{};
            }
        };

        /// Log metrics every 10,000 ticks (~100s at 10ms/tick).
        const metrics_interval_ticks = 10_000;

        /// 30 seconds at 10ms/tick.
        pub const request_timeout_ticks = 3000;

        /// Sidecar response deadline: 5 seconds at 10ms/tick.
        /// If the pipeline has been pending (waiting for sidecar
        /// RESULT) for this many ticks, terminate the connection.
        /// A stuck handler (infinite loop, deadlocked await, long GC)
        /// blocks the serial pipeline — all requests stall.
        const sidecar_response_timeout_ticks: u32 = 500;

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
        pipeline_slots: [pipeline_slots_max]PipelineSlot = .{@as(PipelineSlot, .{})} ** pipeline_slots_max,
        /// Which slot holds the exclusive write lock (null = free).
        /// SQLite WAL mode allows concurrent reads but one writer.
        /// Only one slot can be in .handle at a time; others wait
        /// in .handle_wait until the lock is released.
        handle_lock: ?u8 = null,
        /// Round-robin index for find_free_slot dispatch.
        next_slot: u8 = 0,

        /// Per-slot handlers — domain dispatch (native or sidecar).
        /// Each handler instance owns its per-request state and, for
        /// sidecar, its paired client pointer. Zero-size for native
        /// handlers (comptime-eliminated).
        ///
        /// Handlers MUST be per-slot, not shared. A shared handler
        /// requires pointer-swapping per dispatch (setting the client
        /// pointer before each call). With concurrent slots, a missed
        /// swap sends a CALL to the wrong sidecar. Per-slot handlers
        /// are permanently wired — no swap, no bug.
        handlers: [pipeline_slots_max]Handlers = .{@as(Handlers, .{})} ** pipeline_slots_max,

        // Sidecar Bus and Client — embedded in the Server (TB pattern:
        // Replica embeds MessageBus). Callbacks use the context pointer
        // set during init to recover the Server. Comptime-eliminated
        // when sidecar_enabled = false (void fields, zero bytes).
        //
        // Three parallel arrays, all sized to pipeline_slots_max:
        //   pipeline_slots[i] — per-request state for slot i
        //   handlers[i]       — domain dispatch for slot i
        //   sidecar_clients[i] — protocol state machine for slot i
        sidecar_bus: SidecarBus = if (App.sidecar_enabled) undefined else {},
        sidecar_clients: if (App.sidecar_enabled)
            [pipeline_slots_max]SidecarClient
        else
            void = if (App.sidecar_enabled)
            undefined
        else {},

        /// Per-connection READY state. Each connection validates its
        /// own READY handshake independently. find_free_slot checks
        /// this to skip slots whose connections aren't ready.
        /// Comptime-eliminated when sidecar is disabled.
        sidecar_connections_ready: if (App.sidecar_enabled)
            [pipeline_slots_max]bool
        else
            void = if (App.sidecar_enabled)
            .{false} ** pipeline_slots_max
        else {},

        /// Whether any sidecar connection is ready.
        /// Read by main.zig for supervisor wiring and by
        /// process_inbox for 503 gating.
        pub fn sidecar_any_ready(server: *const Server) bool {
            if (!App.sidecar_enabled) return false;
            for (server.sidecar_connections_ready) |ready| {
                if (ready) return true;
            }
            return false;
        }

        /// Initialize the server. Allocates the connection pool on the heap.
        /// When sidecar_enabled, also initializes the embedded Bus and Client,
        /// wires per-slot handlers, and starts listening on the socket path.
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
        ///
        /// sidecar_path: unix socket path for the sidecar listener.
        ///   Non-null: calls start_listener (production — creates socket).
        ///   Null: no listener (sim — test sets listen_fd directly after).
        pub fn wire_sidecar(server: *Server, allocator: std.mem.Allocator, sidecar_path: ?[]const u8) !void {
            if (!App.sidecar_enabled) return;
            for (&server.sidecar_clients, &server.handlers, 0..) |*client, *handler, i| {
                client.* = SidecarClient.init();
                handler.sidecar_client = client;
                handler.sidecar_bus = &server.sidecar_bus;
                handler.connection_index = @intCast(i);
            }
            try server.sidecar_bus.init_pool(
                allocator,
                server.io,
                @ptrCast(server),
                sidecar_on_frame,
                sidecar_on_close,
            );
            if (sidecar_path) |path| {
                server.sidecar_bus.start_listener(path);
            }
        }

        pub fn deinit(server: *Server, allocator: std.mem.Allocator) void {
            if (App.sidecar_enabled) {
                server.sidecar_bus.deinit(allocator);
            }
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
            // slot.dispatch_entered = true). sidecar_on_frame also
            // calls commit_dispatch. If tick_accept ran during or after
            // process_inbox, a bus recv callback could fire while
            // slot.dispatch_entered is true → assertion failure.
            // tick_accept only accepts new connections — it never
            // delivers frames (that happens in IO.run_for_ns, which
            // runs after tick returns). This ordering is safe.
            if (App.sidecar_enabled) server.sidecar_bus.tick_accept();
            server.maybe_accept();
            server.process_inbox();
            server.wake_handle_waiters();
            if (App.sidecar_enabled) server.timeout_sidecar_response();
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
            if (!server.any_slot_active()) {
                // realtime() returns nanoseconds; SM uses seconds.
                server.state_machine.set_time(@divTrunc(server.time.realtime(), std.time.ns_per_s));
            }

            // Transaction boundary moved to commit_dispatch (.handle stage).
            // WAL recording enabled there too. process_inbox only does
            // routing + pipeline start.

            for (server.connections) |*conn| {
                if (conn.state != .ready) continue;

                // Skip connections already assigned to a pipeline slot.
                // A connection stays .ready during async dispatch (no
                // response sent yet). Without this check, process_inbox
                // would dispatch the same connection to multiple slots.
                if (server.connection_dispatched(conn)) continue;

                // Sidecar not connected → 503 immediately, no pipeline needed.
                // Handled here (server level), not in the pipeline — the 503
                // is a framework concern, not a per-request concern.
                if (App.sidecar_enabled and !server.sidecar_any_ready()) {
                    const resp = sidecar_unavailable_response(conn);
                    conn.set_response(resp.offset, resp.len);
                    conn.keep_alive = false;
                    continue;
                }

                // Find a free slot — round-robin across ready connections.
                const slot = server.find_free_slot() orelse break;

                // Start pipeline at .route — routing is the first stage.
                slot.stage = .route;
                slot.pending_since = server.tick_count;
                slot.connection = conn;
                server.commit_dispatch(slot);
            }
        }

        /// Find a free pipeline slot. Round-robin across slots that have
        /// a ready sidecar connection. Native handlers always use slot[0].
        /// Returns null if no slot is free or no connections are ready.
        fn find_free_slot(server: *Server) ?*PipelineSlot {
            if (!App.sidecar_enabled) {
                const slot = &server.pipeline_slots[0];
                return if (slot.stage == .idle) slot else null;
            }
            // Round-robin: start from next_slot to distribute evenly.
            var i: u8 = 0;
            while (i < pipeline_slots_max) : (i += 1) {
                const idx = (server.next_slot +% i) % pipeline_slots_max;
                const slot = &server.pipeline_slots[idx];
                if (slot.stage == .idle and server.sidecar_connections_ready[idx]) {
                    server.next_slot = (idx +% 1) % pipeline_slots_max;
                    return slot;
                }
            }
            return null;
        }

        /// Wake slots waiting for the handle lock. Called from tick
        /// after process_inbox. Each woken slot's dispatch is a
        /// separate top-level call — no re-entrancy, no pointer
        /// corruption. Handle is synchronous: acquire lock, write,
        /// release, continue to render. After each dispatch, the
        /// lock is free for the next waiter.
        fn wake_handle_waiters(server: *Server) void {
            for (&server.pipeline_slots) |*slot| {
                if (server.handle_lock != null) return;
                if (slot.stage == .handle_wait) {
                    slot.stage = .handle;
                    server.commit_dispatch(slot);
                }
            }
        }

        /// Whether a connection is already assigned to a pipeline slot.
        /// Prevents dispatching the same connection to multiple slots
        /// (the connection stays .ready during async dispatch).
        fn connection_dispatched(server: *const Server, conn: *const Connection) bool {
            for (&server.pipeline_slots) |*slot| {
                if (slot.stage != .idle and slot.connection == conn) return true;
            }
            return false;
        }

        /// Whether any pipeline slot is currently active (non-idle).
        fn any_slot_active(server: *const Server) bool {
            for (&server.pipeline_slots) |*slot| {
                if (slot.stage != .idle) return true;
            }
            return false;
        }

        /// Derive slot index from pointer. Slot index = position in
        /// pipeline_slots array = paired bus connection index.
        /// No mapping table. Direct pairing by array position.
        /// Do NOT add a routing table — the index IS the route.
        fn slot_index(server: *const Server, slot: *const PipelineSlot) u8 {
            const base = @intFromPtr(&server.pipeline_slots[0]);
            const addr = @intFromPtr(slot);
            const offset = addr - base;
            assert(offset % @sizeOf(PipelineSlot) == 0); // aligned to slot boundary
            const idx = offset / @sizeOf(PipelineSlot);
            assert(idx < pipeline_slots_max);
            return @intCast(idx);
        }

        /// Pipeline state machine — drives route → prefetch → handle → render.
        /// Called from process_inbox (start). When a handler returns .pending,
        /// the async callback calls commit_dispatch to resume.
        /// TB's commit_dispatch pattern.
        ///
        /// Each stage either completes (advance to next) or pends (return).
        /// For native handlers, all stages complete in one call. For async
        /// handlers (Phase 2), a stage may return .pending.
        fn commit_dispatch(server: *Server, slot: *PipelineSlot) void {
            // Re-entrancy guard (TB pattern).
            assert(!slot.dispatch_entered);
            slot.dispatch_entered = true;
            defer slot.dispatch_entered = false;

            const sm = server.state_machine;
            const conn = slot.connection orelse return;
            const idx = server.slot_index(slot);
            const handler = &server.handlers[idx];

            // Bounded loop (TB pattern). 4 advancing stages (route →
            // prefetch → handle → render) × 2 for safety. .handle_wait
            // returns immediately (never consumes an iteration). If we
            // ever loop more than 8 times, a bug caused a backward jump
            // or infinite cycle — crash immediately.
            for (0..8) |_| {
                switch (slot.stage) {
                    .idle => return,

                    .route => {
                        // Route: parse HTTP and resolve to typed Message.
                        // Note: 503 (sidecar not connected) is handled in
                        // process_inbox before the pipeline starts.
                        const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                            .complete => |p| p,
                            .incomplete, .invalid => unreachable,
                        };
                        conn.is_datastar_request = parsed.is_datastar_request;

                        var msg = handler.handler_route(parsed.method, parsed.path, parsed.body) orelse {
                            if (handler.is_handler_pending()) return;
                            log.mark.warn("unmapped request: {s} {s} fd={d}", .{ @tagName(parsed.method), parsed.path, conn.fd });
                            const resp = unmapped_response(conn);
                            conn.set_response(resp.offset, resp.len);
                            conn.keep_alive = false;
                            server.pipeline_reset(slot);
                            return;
                        };
                        msg.set_credential(parsed.identity_cookie);

                        slot.msg = msg;
                        slot.stage = .prefetch;
                        sm.tracer.start(.prefetch, idx);
                        continue;
                    },

                    .prefetch => {
                        const msg = slot.msg.?;

                        // Auth: resolve credential → identity (once per request).
                        if (slot.identity == null) {
                            slot.identity = sm.resolve_credential(msg);
                        }

                        // Handler prefetch — may return null (busy or pending).
                        slot.cache = handler.handler_prefetch(sm.storage, &msg);
                        if (slot.cache != null) {
                            sm.tracer.stop(.prefetch, idx, msg.operation);
                            sm.tracer.start(.execute, idx);
                            slot.stage = .handle;
                            continue;
                        }

                        if (handler.is_handler_pending()) return; // async IO in-flight

                        // Busy — retry next tick.
                        sm.tracer.cancel(.prefetch, idx);
                        server.pipeline_reset(slot);
                        return;
                    },

                    .handle => {
                        const msg = slot.msg.?;
                        assert(slot.cache != null);
                        assert(slot.identity != null);
                        // Invariant: handle result not yet produced.
                        assert(slot.pipeline_resp == null);

                        // Exclusive write lock — SQLite WAL allows
                        // concurrent reads but one writer at a time.
                        if (server.handle_lock) |_| {
                            slot.stage = .handle_wait;
                            return;
                        }
                        server.handle_lock = idx;

                        const cache = slot.cache.?;
                        const identity = slot.identity.?;

                        const fw = Handlers.FwCtx{
                            .identity = identity,
                            .now = sm.now,
                            .is_sse = false, // handle stage; SSE resolved at render
                        };

                        // Execute handler inside a transaction.
                        sm.begin_batch();

                        var write_view = if (server.wal != null)
                            Storage.WriteView.init_recording(sm.storage, &server.wal_record_scratch)
                        else
                            Storage.WriteView.init(sm.storage);

                        const handle_result = handler.handler_execute(
                            cache,
                            msg,
                            fw,
                            &write_view,
                        );

                        // WAL: log SQL writes.
                        if (server.wal) |wal| {
                            if (!wal.disabled and msg.operation.is_mutation()) {
                                wal.append_writes(
                                    msg.operation,
                                    sm.now,
                                    if (write_view.record_buf) |buf| buf[0..write_view.record_pos] else "",
                                    write_view.record_count,
                                    &server.wal_scratch,
                                );
                            }
                        }

                        sm.commit_batch();

                        // Build pipeline response from handler result + auth.
                        const is_auth = identity.is_authenticated != 0 or
                            handle_result.session_action == .set_authenticated;

                        slot.pipeline_resp = .{
                            .status = handle_result.status,
                            .session_action = handle_result.session_action,
                            .user_id = identity.user_id,
                            .is_authenticated = is_auth,
                            .is_new_visitor = identity.is_new != 0,
                        };

                        sm.tracer.count_status(handle_result.status);

                        // Release write lock.
                        assert(server.handle_lock.? == idx);
                        server.handle_lock = null;

                        slot.stage = .render;
                        continue;
                    },

                    .handle_wait => {
                        // Waiting for handle_lock. wake_handle_waiters
                        // sets stage back to .handle when the lock is free.
                        return;
                    },

                    .render => {
                        const msg = slot.msg.?;
                        assert(slot.pipeline_resp != null);
                        assert(slot.identity != null);

                        const pipeline_resp = slot.pipeline_resp.?;
                        const cache = slot.cache.?;
                        const identity = slot.identity.?;

                        const fw = Handlers.FwCtx{
                            .identity = identity,
                            .now = sm.now,
                            .is_sse = conn.is_datastar_request,
                        };

                        const ro = Storage.ReadView.init(sm.storage);
                        // render_scratch_buf is shared across slots. Safe because
                        // render completion (write to buf + encode_and_respond) is
                        // driven by sequential frame callbacks — only one slot
                        // completes render per frame. Multiple slots can be in
                        // .render pending simultaneously, but only one writes
                        // to the buffer at a time.
                        const html = handler.handler_render(
                            cache,
                            msg.operation,
                            pipeline_resp.status,
                            fw,
                            &App.render_scratch_buf,
                            ro,
                        ) orelse return; // pending — sidecar render in-flight

                        server.encode_and_respond(slot, conn, msg, pipeline_resp, html);
                        return;
                    },

                }
            } else unreachable; // loop bound exceeded — pipeline bug
        }

        /// Encode response and send to client.
        fn encode_and_respond(
            server: *Server,
            slot: *PipelineSlot,
            conn: *Connection,
            msg: App.Message,
            pipeline_resp: PipelineResponse,
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

            const trace_idx = server.slot_index(slot);
            sm.tracer.stop(.execute, trace_idx, msg.operation);
            sm.tracer.trace_log(msg.operation, commit_result.status, conn.fd, trace_idx);

            conn.set_response(commit_result.response.offset, commit_result.response.len);
            conn.keep_alive = commit_result.response.keep_alive;

            server.pipeline_reset(slot);
        }

        /// Reset the pipeline to idle. Called on completion, busy, or failure.
        /// NOTE: callers are responsible for stopping/cancelling their own
        /// tracer spans before calling pipeline_reset. The .busy branch
        /// cancels .prefetch, the .render stage stops .execute, etc.
        fn pipeline_reset(server: *Server, slot: *PipelineSlot) void {
            // A slot holding the write lock can't be externally reset —
            // .handle is synchronous, completes within the tick. If this
            // fires, the event loop model changed and the lock would leak.
            const idx = server.slot_index(slot);
            if (server.handle_lock) |lock_holder| {
                assert(lock_holder != idx);
            }
            server.handlers[idx].reset_handler_state();
            slot.reset();
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
        /// - Before handshake: expects READY frame. Validates version.
        ///   Marks connection ready.
        /// - After handshake: routes to connection's paired handler.
        pub fn sidecar_on_frame(ctx: *anyopaque, connection_index: u8, frame: []const u8) void {
            if (!App.sidecar_enabled) unreachable;
            const server: *Server = @ptrCast(@alignCast(ctx));

            if (!server.sidecar_connections_ready[connection_index]) {
                // Per-connection READY handshake. Each connection
                // validates independently.
                const protocol = @import("../protocol.zig");
                const ready = protocol.parse_ready_frame(frame) orelse {
                    log.warn("sidecar: invalid READY frame on slot {d}, terminating", .{connection_index});
                    server.sidecar_bus.terminate_connection(connection_index);
                    return;
                };
                if (ready.version != protocol.protocol_version) {
                    log.warn("sidecar: version mismatch: expected {d}, got {d}", .{
                        protocol.protocol_version, ready.version,
                    });
                    server.sidecar_bus.terminate_connection(connection_index);
                    return;
                }
                server.sidecar_connections_ready[connection_index] = true;
                log.info("sidecar: slot {d} ready (version={d})", .{ connection_index, ready.version });
                return;
            }

            // All connections are active — each serves its own pipeline
            // slot. No active/standby concept. Do NOT add a standby
            // check here — it would prevent concurrent dispatch.
            // Each connection is permanently paired with its slot
            // (slot index = connection index). Routing is direct.
            const handler = &server.handlers[connection_index];
            handler.process_sidecar_frame(frame, server.state_machine.storage);

            // Protocol violation → terminate connection.
            if (server.sidecar_clients[connection_index].protocol_violation) {
                log.warn("sidecar: protocol violation detected on slot {d}, terminating", .{connection_index});
                server.terminate_sidecar_connection(connection_index);
                return;
            }

            // Resume pipeline on the connection's paired slot.
            const slot = &server.pipeline_slots[connection_index];
            if (slot.stage != .idle and !handler.is_handler_pending()) {
                server.commit_dispatch(slot);
            }
        }

        /// Called when the sidecar bus connection closes.
        pub fn sidecar_on_close(ctx: *anyopaque, connection_index: u8, reason: Handlers.BusType.Connection.CloseReason) void {
            if (!App.sidecar_enabled) unreachable;
            const server: *Server = @ptrCast(@alignCast(ctx));
            log.info("sidecar: slot {d} disconnected (reason={s})", .{ connection_index, @tagName(reason) });

            // Clear per-connection ready state — slot is disabled until
            // the sidecar reconnects and completes a new READY handshake.
            server.sidecar_connections_ready[connection_index] = false;

            // Pipeline recovery — reset handler and recover slot.
            server.handlers[connection_index].on_sidecar_close();

            const slot = &server.pipeline_slots[connection_index];
            if (slot.stage == .render) {
                server.render_crash_fallback(slot);
                return;
            }

            if (slot.stage != .idle) {
                const sm = server.state_machine;
                switch (slot.stage) {
                    .route => {},
                    .prefetch => sm.tracer.cancel(.prefetch, connection_index),
                    .render => unreachable,
                    .handle, .handle_wait, .idle => {},
                }
                server.pipeline_reset(slot);
            } else {
                server.handlers[connection_index].reset_handler_state();
            }
        }

        /// Terminate a specific sidecar bus connection. on_close will
        /// fire, clearing sidecar_connections_ready and recovering
        /// the slot. main.zig detects the disconnect and tells the
        /// supervisor to restart.
        fn terminate_sidecar_connection(server: *Server, connection_idx: u8) void {
            if (!App.sidecar_enabled) unreachable;
            server.sidecar_bus.terminate_connection(connection_idx);
        }

        /// Sidecar response timeout — terminate the connection if the pipeline
        /// has been pending for too long. A stuck handler (infinite loop,
        /// deadlocked await, long GC) blocks the serial pipeline.
        /// Uses existing recovery: kill → on_close → 503 or render fallback.
        fn timeout_sidecar_response(server: *Server) void {
            if (!server.sidecar_any_ready()) return;

            for (&server.pipeline_slots, 0..) |*slot, i| {
                if (slot.stage == .idle) continue;

                // Only timeout when actually waiting for sidecar response.
                // .handle is synchronous — no sidecar involvement.
                const pending = switch (slot.stage) {
                    .route, .prefetch, .render => server.handlers[i].is_handler_pending(),
                    .handle, .handle_wait, .idle => false,
                };
                if (!pending) continue;

                const elapsed = server.tick_count -% slot.pending_since;
                if (elapsed >= sidecar_response_timeout_ticks) {
                    log.warn("sidecar: response timeout ({d} ticks, stage={s}, op={s}, slot={d}), terminating", .{
                        elapsed,
                        @tagName(slot.stage),
                        if (slot.msg) |msg| @tagName(msg.operation) else "unknown",
                        i,
                    });
                    server.terminate_sidecar_connection(@intCast(i));
                    return;
                }
            }
        }

        /// Render crash fallback — writes committed, sidecar gone.
        /// Send a minimal response using committed pipeline data.
        /// Never retry — retrying re-executes handle → duplicate writes.
        fn render_crash_fallback(server: *Server, slot: *PipelineSlot) void {
            const conn = slot.connection orelse {
                server.pipeline_reset(slot);
                return;
            };
            // Connection may have timed out or closed while the pipeline
            // was waiting for the sidecar render. Only send the fallback
            // if the connection is still ready to receive a response.
            if (conn.state != .ready) {
                server.pipeline_reset(slot);
                return;
            }
            const msg = slot.msg.?;
            const pipeline_resp = slot.pipeline_resp.?;

            // Minimal response: operation succeeded, render degraded.
            const fallback_html = "<html><body>Operation completed. Refresh for full page.</body></html>";
            server.encode_and_respond(slot, conn, msg, pipeline_resp, fallback_html);
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
                    for (&server.pipeline_slots, 0..) |*slot, si| {
                        if (slot.connection == conn and slot.stage != .idle) {
                            const sm = server.state_machine;
                            const slot_i: u8 = @intCast(si);
                            switch (slot.stage) {
                                .route => {}, // no tracer span active during route
                                .prefetch => sm.tracer.cancel(.prefetch, slot_i),
                                .render => sm.tracer.cancel(.execute, slot_i),
                                .handle, .handle_wait, .idle => {},
                            }
                            server.pipeline_reset(slot);
                            break; // one connection per slot
                        }
                    }
                    conn.state = .closing;
                }
            }
        }

        /// Write a short error response for requests that parsed as valid HTTP
        /// but couldn't be routed (unknown path, malformed JSON, bad UUID, etc.).
        fn unmapped_response(conn: *Connection) struct { offset: u32, len: u32 } {
            const body = "invalid request\n";
            const response = "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                body;
            @memcpy(conn.send_buf[0..response.len], response);
            return .{ .offset = 0, .len = response.len };
        }

        /// 503-equivalent: sidecar not connected. Distinct from
        /// unmapped (404-like). Connection: close — client should retry.
        fn sidecar_unavailable_response(conn: *Connection) struct { offset: u32, len: u32 } {
            const body = "service unavailable\n";
            const response = "HTTP/1.1 503 Service Unavailable\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                body;
            @memcpy(conn.send_buf[0..response.len], response);
            return .{ .offset = 0, .len = response.len };
        }

        /// Cross-check structural invariants after every tick.
        /// Connection-level invariants are checked by Connection.invariants().
        /// Handler-level invariants checked per-slot.
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

            // Pipeline cross-invariants — slot.stage and its associated
            // fields must be consistent. Pair assertion with commit_dispatch
            // which sets them and PipelineSlot.reset() which clears them.
            var active_slots: u32 = 0;
            for (&server.pipeline_slots) |*slot| {
                // dispatch_entered is set/cleared by commit_dispatch's defer.
                // After tick returns, no slot should be mid-dispatch.
                assert(!slot.dispatch_entered);
                if (slot.stage != .idle) {
                    active_slots += 1;
                    assert(slot.connection != null);
                } else {
                    assert(slot.connection == null);
                    assert(slot.msg == null);
                    assert(slot.pipeline_resp == null);
                    assert(slot.cache == null);
                    assert(slot.identity == null);
                    assert(slot.pending_since == 0);
                }
            }
            // Concurrent pipeline: active_slots can be up to pipeline_slots_max.
            assert(active_slots <= pipeline_slots_max);

            // handle_lock must be null after tick — .handle is synchronous,
            // acquired and released within the same tick. If the lock is
            // held after tick, a slot entered .handle but didn't complete.
            assert(server.handle_lock == null);

            // Handler invariants — cross-checks prefetch_phase vs call_state.
            // Each handler checked independently — no shared state.
            for (&server.handlers) |*handler| {
                handler.invariants();
            }
        }
    };
}
