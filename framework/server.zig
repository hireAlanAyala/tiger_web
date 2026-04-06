const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const http = @import("http.zig");
const ConnectionType = @import("connection.zig").ConnectionType;
const Time = @import("time.zig").Time;
const constants = @import("constants.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.server));
const WalType = @import("wal.zig").WalType;
const Trace = @import("../trace.zig");

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

    // V2 dispatch — pipelined stateless protocol. Coexists with v1
    // handlers. The server routes frames to either v1 or v2 based
    // on protocol version (TODO: version negotiation).
    const DispatchV2 = if (App.sidecar_enabled) @import("../sidecar_dispatch.zig").SidecarDispatchType(Storage, SidecarBus) else void;

    // Pipeline slot count — derived from bus connections.
    const slots_max: u8 = if (App.sidecar_enabled) SidecarBus.connections_max else 1;
    const StateMachine = App.StateMachineWith(Storage);

    comptime {
        // Validate StateMachine interface — framework services.
        assert(@hasDecl(StateMachine, "set_time"));
        assert(@hasDecl(StateMachine, "begin_batch"));
        assert(@hasDecl(StateMachine, "commit_batch"));
        assert(@hasDecl(StateMachine, "resolve_credential"));
        assert(@hasField(StateMachine, "secret_key"));
        assert(@hasField(StateMachine, "now"));
    }

    return struct {
        const Server = @This();

        pub const max_connections = constants.max_connections;

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

        /// Sidecar response deadline: 5 seconds at 10ms/tick.
        /// If the pipeline has been pending (waiting for sidecar
        /// RESULT) for this many ticks, terminate the connection.
        /// A stuck handler (infinite loop, deadlocked await, long GC)
        /// blocks the serial pipeline — all requests stall.
        const sidecar_response_timeout_ticks: u32 = 500;

        // --- Fields ---

        io: *IO,
        state_machine: *StateMachine,
        tracer: *Trace.Tracer,
        time: Time,

        listen_fd: IO.fd_t,

        connections: []Connection,
        connections_used: u32,

        /// TB pattern: suspended connections queue. Connections with
        /// a complete request that couldn't be dispatched (no free
        /// pipeline slot). Drained when a slot frees up.
        suspended_head: ?*Connection = null,
        suspended_tail: ?*Connection = null,

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
        dispatch_v2: if (App.sidecar_enabled) DispatchV2 else void = if (App.sidecar_enabled) .{} else {},
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
            [App.sidecar_count]bool
        else
            void = if (App.sidecar_enabled)
            .{false} ** App.sidecar_count
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
            tracer: *Trace.Tracer,
            listen_fd: IO.fd_t,
            time: Time,
            wal: ?*Wal,
        ) !Server {
            const connections = try allocator.alloc(Connection, max_connections);
            errdefer allocator.free(connections);

            // Connections are initialized with zeroed state. They're
            // wired with callbacks below after the server is at its
            // final address. TB pattern: init connections after the
            // containing struct is constructed.
            // Connections are placeholder-initialized. wire_connections()
            // must be called after the server is at its final address.
            for (connections) |*conn| {
                conn.* = undefined;
                conn.state = .free;
                conn.fd = 0;
                conn.recv_completion = .{};
                conn.send_completion = .{};
            }

            return Server{
                .io = io,
                .state_machine = state_machine,
                .tracer = tracer,
                .time = time,
                .listen_fd = listen_fd,
                .connections = connections,
                .connections_used = 0,
                .wal = wal,
                .tick_count = 0,
            };
        }

        /// Wire connection callbacks after server is at its final address.
        /// Must be called before the first tick. TB pattern: connections
        /// hold a context pointer to the server for callback dispatch.
        pub fn wire_connections(server: *Server) void {
            for (server.connections) |*conn| {
                conn.* = Connection.init(
                    server.io,
                    @ptrCast(server),
                    on_connection_ready,
                    on_connection_close,
                );
            }
        }

        /// Callback: connection has a complete HTTP request. Dispatch
        /// to the pipeline immediately — don't wait for tick.
        /// Callback: connection has a complete HTTP request.
        /// TB pattern: dispatch immediately, or suspend if no slot.
        fn on_connection_ready(ctx: *anyopaque, conn: *Connection) void {
            const server: *Server = @ptrCast(@alignCast(ctx));
            server.try_dispatch(conn);
        }

        /// Try to dispatch a ready connection. If no slot available,
        /// push to suspended queue. TB pattern: message stays in recv
        /// buffer, retried when resources free up.
        fn try_dispatch(server: *Server, conn: *Connection) void {
            assert(conn.state == .ready);

            // Sidecar not connected → 503 immediately.
            if (App.sidecar_enabled and !server.sidecar_any_ready()) {
                const resp = sidecar_unavailable_response(conn);
                conn.keep_alive = false;
                conn.set_response(resp.offset, resp.len);
                return;
            }

            // Already dispatched to a slot — don't double-dispatch.
            if (server.connection_dispatched(conn)) return;

            // V2 dispatch path — pipelined stateless protocol.
            if (App.sidecar_enabled and App.protocol_v2) {
                server.try_dispatch_v2(conn);
                return;
            }

            // V1 path — sequential slot-based dispatch.
            const slot = server.find_free_slot() orelse {
                server.suspend_connection(conn);
                return;
            };

            slot.stage = .route;
            slot.pending_since = server.tick_count;
            slot.connection = conn;
            server.commit_dispatch(slot);
        }

        // =============================================================
        // V2 dispatch — pipelined stateless protocol
        // =============================================================

        fn try_dispatch_v2(server: *Server, conn: *Connection) void {
            if (!App.sidecar_enabled or !App.protocol_v2) unreachable;

            const entry = server.dispatch_v2.acquire_entry() orelse {
                server.suspend_connection(conn);
                return;
            };

            // Parse HTTP to get method/path/body for the route CALL.
            const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                .complete => |p| p,
                .incomplete, .invalid => unreachable,
            };
            conn.is_datastar_request = parsed.is_datastar_request;

            if (!server.dispatch_v2.start_request(entry, parsed.method, parsed.path, parsed.body, @ptrCast(conn))) {
                entry.reset();
                server.suspend_connection(conn);
                return;
            }
        }

        /// V2: process completed entries — encode response and send.
        fn process_v2_completions(server: *Server) void {
            if (!App.sidecar_enabled or !App.protocol_v2) return;

            for (&server.dispatch_v2.entries) |*entry| {
                switch (entry.stage) {
                    .write_pending => {
                        // Execute writes under handle_lock.
                        if (server.handle_lock != null) continue;

                        const entry_idx = (@intFromPtr(entry) - @intFromPtr(&server.dispatch_v2.entries)) / @sizeOf(DispatchV2.Entry);
                        server.handle_lock = @intCast(entry_idx);

                        const sm = server.state_machine;
                        log.debug("v2 write: mutation={} write_count={d} writes_len={d}", .{ entry.is_mutation, entry.handle_write_count, entry.handle_writes.len });
                        if (entry.is_mutation) sm.begin_batch();

                        // Execute writes through WriteView (same as v1 path).
                        if (entry.handle_write_count > 0) {
                            var write_view = Storage.WriteView.init(sm.storage);
                            const data = entry.handle_writes;
                            var dpos: usize = 0;
                            for (0..entry.handle_write_count) |_| {
                                if (dpos + 2 > data.len) break;
                                const sql_len = std.mem.readInt(u16, data[dpos..][0..2], .big);
                                dpos += 2;
                                if (dpos + sql_len > data.len) break;
                                const sql = data[dpos..][0..sql_len];
                                dpos += sql_len;
                                if (dpos >= data.len) break;
                                const param_count = data[dpos];
                                dpos += 1;
                                const params_start = dpos;
                                dpos = @import("../sidecar.zig").SidecarClientType(SidecarBus).skip_params(data, dpos, param_count) orelse break;
                                const write_ok = write_view.execute_raw(sql, data[params_start..dpos], param_count);
                                log.debug("v2 execute_raw: ok={} sql_len={d} params={d}", .{ write_ok, sql.len, param_count });
                            }
                        }

                        if (entry.is_mutation) sm.commit_batch();

                        server.handle_lock = null;
                        server.dispatch_v2.write_committed(entry);
                        server.dispatch_v2.advance(sm.storage);
                    },
                    .render_complete => {
                        // Encode response and send to the connection.
                        const conn: *Connection = @ptrCast(@alignCast(entry.connection orelse {
                            server.dispatch_v2.release_entry(entry);
                            continue;
                        }));

                        const sm = server.state_machine;
                        const commit_result = App.encode_response(
                            entry.handle_status,
                            entry.html,
                            &conn.send_buf,
                            conn.is_datastar_request,
                            entry.handle_session_action,
                            entry.msg.user_id,
                            false, // is_authenticated — TODO: wire from entry
                            false, // is_new_visitor — TODO: wire from entry
                            sm.secret_key,
                        );

                        conn.keep_alive = commit_result.response.keep_alive;
                        conn.set_response(commit_result.response.offset, commit_result.response.len);

                        server.dispatch_v2.release_entry(entry);

                        // Resume a suspended connection into the freed entry.
                        if (server.suspended_head) |susp| {
                            server.suspended_head = susp.active_next;
                            if (server.suspended_head == null) server.suspended_tail = null;
                            susp.active_next = null;
                            if (susp.state == .ready) {
                                server.try_dispatch(susp);
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        fn suspend_connection(server: *Server, conn: *Connection) void {
            // Don't add duplicates.
            if (conn.active_next != null) return;
            if (server.suspended_head == conn) return;

            conn.active_next = null;
            if (server.suspended_tail) |tail| {
                tail.active_next = conn;
            } else {
                server.suspended_head = conn;
            }
            server.suspended_tail = conn;
        }

        /// Drain suspended connections — called when a pipeline slot
        /// frees up. TB pattern: resume_receive re-drains suspended
        /// messages when journal/repair slots become available.
        fn resume_suspended(server: *Server) void {
            var conn = server.suspended_head;
            server.suspended_head = null;
            server.suspended_tail = null;

            while (conn) |c| {
                const next = c.active_next;
                c.active_next = null;
                conn = next;

                if (c.state == .ready) {
                    server.try_dispatch(c);
                }
            }
        }

        /// Callback: connection closed. Free resources and handle
        /// pipeline cleanup.
        fn on_connection_close(ctx: *anyopaque, conn: *Connection) void {
            const server: *Server = @ptrCast(@alignCast(ctx));
            server.connections_used -= 1;

            // Cancel any pipeline slot using this connection.
            for (&server.pipeline_slots, 0..) |*slot, si| {
                if (slot.connection == conn and slot.stage != .idle) {
                    server.tracer.cancel_slot(@intCast(si));
                    server.pipeline_reset(slot);
                    break;
                }
            }
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
                handler.connection_index = @intCast(i % App.sidecar_count);
            }
            // Wire v2 dispatch module.
            server.dispatch_v2.bus = &server.sidecar_bus;
            server.dispatch_v2.connection_index = 0;
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

        /// One tick of the server. Periodic work only — no connection
        /// scanning. TB pattern: callbacks drive request processing
        /// (recv_callback → dispatch → send). The tick handles:
        ///
        /// 1. Accept new connections (drain pending)
        /// 2. Update wall-clock time
        /// 3. Resume suspended connections (no-slot retry)
        /// 4. Wake handle_lock waiters
        /// 5. Sidecar response timeout (scans pipeline_slots_max only)
        /// 6. Metrics emission
        pub fn tick(server: *Server) void {
            server.tick_count +%= 1;
            server.time.tick();
            defer server.invariants();
            if (App.sidecar_enabled) server.sidecar_bus.tick_accept();
            server.maybe_accept();
            server.update_time();
            server.resume_suspended();
            server.wake_handle_waiters();
            if (App.sidecar_enabled) server.timeout_sidecar_response();
            server.process_v2_completions();
            server.log_metrics();
        }

        // --- Accept ---

        /// Drain all pending connections per tick. Direct non-blocking
        /// accept — same primitive as the sidecar bus. No epoll
        /// registration, no ONESHOT race, deterministic per-tick.
        fn maybe_accept(server: *Server) void {
            while (server.connections_used < server.connections.len) {
                const accepted_fd = server.io.try_accept(server.listen_fd) orelse return;
                IO.set_tcp_options(accepted_fd);

                const conn = for (server.connections) |*conn| {
                    if (conn.state == .free) break conn;
                } else unreachable;

                conn.on_accept(accepted_fd);
                server.connections_used += 1;
                log.debug("accepted connection fd={d}", .{accepted_fd});
            }
        }

        // --- Inbox: process ready requests ---

        /// Update wall-clock time when no pipeline is in-flight.
        fn update_time(server: *Server) void {
            if (!server.any_slot_active()) {
                server.state_machine.set_time(@divTrunc(server.time.realtime(), std.time.ns_per_s));
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
                const conn_idx = idx % App.sidecar_count;
                if (slot.stage == .idle and server.sidecar_connections_ready[conn_idx]) {
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
                            conn.keep_alive = false;
                            conn.set_response(resp.offset, resp.len);
                            server.pipeline_reset(slot);
                            return;
                        };
                        msg.set_credential(parsed.identity_cookie);

                        slot.msg = msg;
                        slot.stage = .prefetch;
                        server.tracer.start(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = idx, .op = @intFromEnum(msg.operation) } });
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
                            server.tracer.stop(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = idx, .op = @intFromEnum(msg.operation) } });
                            server.tracer.start(.{ .pipeline_stage = .{ .stage = .handle, .slot = idx, .op = @intFromEnum(msg.operation) } });
                            slot.stage = .handle;
                            continue;
                        }

                        if (handler.is_handler_pending()) return; // async IO in-flight

                        // Busy — suspend for retry on next tick.
                        server.tracer.cancel_slot(idx);
                        const busy_conn = slot.connection;
                        server.pipeline_reset(slot);
                        if (busy_conn) |bc| {
                            if (bc.state == .ready) server.suspend_connection(bc);
                        }
                        return;
                    },

                    .handle => {
                        const msg = slot.msg.?;
                        assert(slot.cache != null);
                        assert(slot.identity != null);
                        // Invariant: handle result not yet produced.
                        assert(slot.pipeline_resp == null);

                        const is_mutation = msg.operation.is_mutation();

                        // Exclusive write lock — SQLite WAL allows
                        // concurrent reads but one writer at a time.
                        // Read-only operations skip the lock entirely.
                        if (is_mutation) {
                            if (server.handle_lock) |_| {
                                slot.stage = .handle_wait;
                                return;
                            }
                            server.handle_lock = idx;
                        }

                        const cache = slot.cache.?;
                        const identity = slot.identity.?;

                        const fw = Handlers.FwCtx{
                            .identity = identity,
                            .now = sm.now,
                            .is_sse = false, // handle stage; SSE resolved at render
                        };

                        // Execute handler inside a transaction.
                        if (is_mutation) sm.begin_batch();

                        var write_view = if (is_mutation and server.wal != null)
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
                        if (is_mutation) {
                            if (server.wal) |wal| {
                                if (!wal.disabled) {
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
                        }

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

                        server.tracer.stop(.{ .pipeline_stage = .{ .stage = .handle, .slot = idx, .op = @intFromEnum(msg.operation) } });
                        server.tracer.count(.{ .requests_by_operation = .{ .operation = msg.operation } }, 1);
                        server.tracer.count(.{ .requests_by_status = .{ .status = handle_result.status } }, 1);

                        // Release write lock (mutations only).
                        if (is_mutation) {
                            assert(server.handle_lock.? == idx);
                            server.handle_lock = null;
                        }

                        slot.stage = .render;
                        server.tracer.start(.{ .pipeline_stage = .{ .stage = .render, .slot = idx, .op = @intFromEnum(msg.operation) } });
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
            server.tracer.stop(.{ .pipeline_stage = .{ .stage = .render, .slot = trace_idx, .op = @intFromEnum(msg.operation) } });

            // Set keep_alive BEFORE set_response — set_response triggers
            // submit_send which may complete synchronously via send_now.
            // send_complete checks keep_alive to decide close vs recv.
            conn.keep_alive = commit_result.response.keep_alive;
            conn.set_response(commit_result.response.offset, commit_result.response.len);

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

            // Immediately dispatch the next suspended connection to
            // the freed slot. Without this, the slot idles until the
            // next tick() calls resume_suspended — adding up to one
            // full tick interval (~10ms) of latency per request.
            if (server.suspended_head) |conn| {
                server.suspended_head = conn.active_next;
                if (server.suspended_head == null) server.suspended_tail = null;
                conn.active_next = null;
                if (conn.state == .ready) {
                    server.try_dispatch(conn);
                }
            }
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
                const accepted_version = if (App.protocol_v2) 2 else protocol.protocol_version;
                if (ready.version != accepted_version) {
                    log.warn("sidecar: version mismatch: expected {d}, got {d}", .{
                        accepted_version, ready.version,
                    });
                    server.sidecar_bus.terminate_connection(connection_index);
                    return;
                }
                server.sidecar_connections_ready[connection_index] = true;
                log.info("sidecar: slot {d} ready (version={d})", .{ connection_index, ready.version });
                return;
            }

            // V2 dispatch — route frame to dispatch module.
            if (App.protocol_v2) {
                server.dispatch_v2.on_frame(frame, server.state_machine.storage);
                server.process_v2_completions();
                return;
            }

            // V1: route frame to the correct handler/slot.
            const slot_idx: u8 = if (pipeline_slots_max == App.sidecar_count)
                connection_index
            else
                server.find_slot_by_frame(frame) orelse {
                    log.warn("sidecar: frame with unknown request_id on connection {d}", .{connection_index});
                    return;
                };

            const handler = &server.handlers[slot_idx];
            handler.process_sidecar_frame(frame, server.state_machine.storage);

            // Protocol violation → terminate the bus connection.
            if (server.sidecar_clients[slot_idx].protocol_violation) {
                log.warn("sidecar: protocol violation on slot {d}, terminating connection {d}", .{ slot_idx, connection_index });
                server.terminate_sidecar_connection(connection_index);
                return;
            }

            // Resume pipeline on the matched slot.
            const slot = &server.pipeline_slots[slot_idx];
            if (slot.stage != .idle and !handler.is_handler_pending()) {
                server.commit_dispatch(slot);
            }
        }

        /// Called when the sidecar bus connection closes. Resets all
        /// pipeline slots that were using this connection.
        pub fn sidecar_on_close(ctx: *anyopaque, connection_index: u8, reason: Handlers.BusType.Connection.CloseReason) void {
            if (!App.sidecar_enabled) unreachable;
            const server: *Server = @ptrCast(@alignCast(ctx));
            log.info("sidecar: connection {d} disconnected (reason={s})", .{ connection_index, @tagName(reason) });

            server.sidecar_connections_ready[connection_index] = false;

            // Reset all slots that map to this connection.
            for (&server.handlers, &server.pipeline_slots, 0..) |*handler, *slot, i| {
                if (handler.connection_index != connection_index) continue;
                handler.on_sidecar_close();

                if (slot.stage == .render) {
                    server.render_crash_fallback(slot);
                } else if (slot.stage != .idle) {
                    server.tracer.cancel_slot(@intCast(i));
                    server.pipeline_reset(slot);
                } else {
                    handler.reset_handler_state();
                }
            }
        }

        /// Find which pipeline slot a sidecar frame belongs to by
        /// matching the request_id in the frame against each slot's
        /// expected_request_id. Returns null if no match (stale frame).
        fn find_slot_by_frame(server: *Server, frame: []const u8) ?u8 {
            if (!App.sidecar_enabled) unreachable;
            // request_id is at bytes 1..5 (after tag byte), big-endian.
            if (frame.len < 5) return null;
            const request_id = std.mem.readInt(u32, frame[1..5], .big);
            for (&server.sidecar_clients, 0..) |*client, i| {
                if (client.call_state == .receiving and client.expected_request_id == request_id) {
                    return @intCast(i);
                }
            }
            return null;
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
                    .closing, .free => {},
                }
            }
            server.tracer.gauge(.connections_active, connections_active);
            server.tracer.gauge(.connections_receiving, connections_receiving);
            server.tracer.gauge(.connections_ready, connections_ready);
            server.tracer.gauge(.connections_sending, connections_sending);

            server.tracer.emit_metrics();
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
            var active_count: u32 = 0;

            for (server.connections) |*conn| {
                conn.invariants();
                if (conn.state != .free) {
                    active_count += 1;
                }
            }

            // connections_used counts active connections.
            assert(server.connections_used == active_count);

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
