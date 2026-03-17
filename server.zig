const std = @import("std");
const assert = std.debug.assert;
const maybe = @import("message.zig").maybe;
const message = @import("message.zig");
const codec = @import("codec.zig");
const http = @import("http.zig");
const auth = @import("auth.zig");
const StateMachineType = @import("state_machine.zig").StateMachineType;
const ConnectionType = @import("connection.zig").ConnectionType;
const render = @import("render.zig");
const Time = @import("time.zig").Time;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.server));
const PRNG = @import("prng.zig");
const Wal = @import("wal.zig").Wal;

/// The server orchestrator, parameterized on the IO and Storage types.
/// In production, IO is the real epoll-based implementation and Storage is SqliteStorage.
/// In simulation, IO is SimIO and Storage is MemoryStorage.
///
/// This is the equivalent of TigerBeetle's Replica — it owns all connections,
/// drives the tick loop, and mediates between network IO and the state machine.
pub fn ServerType(comptime IO: type, comptime Storage: type) type {
    const Connection = ConnectionType(IO);
    const StateMachine = StateMachineType(Storage);

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

        secret_key: *const [auth.key_length]u8,
        prng: PRNG,
        wal: ?*Wal,

        tick_count: u32,

        /// Log metrics every 10,000 ticks (~100s at 10ms/tick).
        const metrics_interval_ticks = 10_000;

        /// 30 seconds at 10ms/tick.
        pub const request_timeout_ticks = 3000;

        /// Initialize the server. Allocates the connection pool on the heap.
        pub fn init(allocator: std.mem.Allocator, io: *IO, state_machine: *StateMachine, listen_fd: IO.fd_t, time: Time, secret_key: *const [auth.key_length]u8, prng_seed: u64, wal: ?*Wal) !Server {
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
                .secret_key = secret_key,
                .prng = PRNG.from_seed(prng_seed),
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
            server.maybe_accept();
            server.process_inbox();
            server.process_followups();
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
            maybe(result < 0);
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
            // Set wall-clock time for this batch — all operations in the tick
            // see the same timestamp.
            server.state_machine.set_time(server.time.realtime());

            // Wrap all writes in a single transaction so the tick pays one
            // fsync instead of one per write. Reads are unaffected (WAL mode).
            // If we crash mid-tick, no responses have been sent yet (flush_outbox
            // runs after process_inbox), so clients see a disconnect and retry.
            server.state_machine.begin_batch();
            defer server.state_machine.commit_batch();

            for (server.connections) |*conn| {
                if (conn.state != .ready) continue;
                if (conn.pending_followup) continue;

                // Re-parse HTTP from recv_buf. Deterministic — same bytes, same result.
                const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                    .complete => |p| p,
                    // Frame was validated by connection, re-parse must succeed.
                    .incomplete, .invalid => unreachable,
                };

                // Route through codec.
                var msg = codec.translate(parsed.method, parsed.path, parsed.body) orelse {
                    log.mark.warn("unmapped request fd={d}", .{conn.fd});
                    conn.state = .closing;
                    continue;
                };
                conn.is_datastar_request = parsed.is_datastar_request;

                // Cookie identity resolution — every visitor gets an identity.
                const existing = if (parsed.identity_cookie) |cv| auth.verify_cookie(cv, server.secret_key) else null;
                const user_id = existing orelse mint_user_id(&server.prng);
                assert(user_id != 0);
                msg.user_id = user_id;
                if (existing == null) {
                    assert(conn.set_cookie_user_id == 0);
                    conn.set_cookie_user_id = user_id;
                }

                // Prefetch. Storage busy → skip, retry next tick.
                server.state_machine.tracer.start(.prefetch);
                if (!server.state_machine.prefetch(msg)) {
                    server.state_machine.tracer.cancel(.prefetch);
                    continue;
                }
                server.state_machine.tracer.stop(.prefetch, msg.operation);

                // Execute.
                assert(msg.user_id != 0);
                server.state_machine.tracer.start(.execute);
                const resp = server.state_machine.commit(msg);
                server.state_machine.tracer.stop(.execute, msg.operation);
                server.state_machine.tracer.trace_log(msg.operation, resp.status, conn.fd);

                // WAL: log mutations after execute. No fsync — SQLite is the authority.
                // If the WAL is disabled (write failure), skip silently.
                if (server.wal) |wal| {
                    if (!wal.disabled and msg.operation.is_mutation()) {
                        const timestamp = server.state_machine.now;
                        const entry = wal.prepare(msg, timestamp);
                        wal.append(&entry);
                    }
                }

                // SSE mutations: defer rendering to process_followups.
                // Store the result status so the follow-up can include an error
                // message alongside the dashboard refresh.
                if (conn.is_datastar_request and msg.operation.is_mutation()) {
                    log.mark.debug("SSE mutation: deferring to follow-up fd={d}", .{conn.fd});
                    conn.pending_followup = true;
                    conn.followup_status = resp.status;
                    conn.followup_operation = msg.operation;
                    continue;
                }

                // Encode response.
                var cookie_hdr_buf: [auth.set_cookie_header_max]u8 = undefined;
                const cookie_hdr: ?[]const u8 = if (conn.set_cookie_user_id != 0)
                    auth.format_set_cookie_header(&cookie_hdr_buf, conn.set_cookie_user_id, server.secret_key)
                else
                    null;
                const r = render.encode_response(&conn.send_buf, msg.operation, resp, conn.is_datastar_request, cookie_hdr, user_id);
                conn.set_response(r.offset, r.len);
                conn.keep_alive = r.keep_alive;
            }
        }

        // --- Follow-ups: refresh dashboard after SSE mutations ---

        fn process_followups(server: *Server) void {
            var any_followup = false;
            for (server.connections) |*conn| {
                if (conn.pending_followup) {
                    any_followup = true;
                    break;
                }
            }
            if (!any_followup) return;

            server.state_machine.begin_batch();
            defer server.state_machine.commit_batch();

            for (server.connections) |*conn| {
                if (!conn.pending_followup) continue;
                assert(conn.state == .ready);
                assert(conn.is_datastar_request);
                assert(conn.followup_operation.is_mutation());

                const msg = message.Message.init(.page_load_dashboard, 0, 0, {});

                // Prefetch. Storage busy → skip, retry next tick.
                server.state_machine.tracer.start(.prefetch);
                if (!server.state_machine.prefetch(msg)) {
                    server.state_machine.tracer.cancel(.prefetch);
                    continue;
                }
                server.state_machine.tracer.stop(.prefetch, .page_load_dashboard);

                server.state_machine.tracer.start(.execute);
                const resp = server.state_machine.commit(msg);
                server.state_machine.tracer.stop(.execute, .page_load_dashboard);

                // Dashboard load itself failed (storage error). The mutation
                // already committed — just close the connection. The client
                // sees a disconnect and can refresh the page.
                if (resp.status != .ok) {
                    conn.pending_followup = false;
                    conn.state = .closing;
                    continue;
                }

                const dashboard = resp.result.page_load_dashboard;

                var cookie_hdr_buf: [auth.set_cookie_header_max]u8 = undefined;
                const cookie_hdr: ?[]const u8 = if (conn.set_cookie_user_id != 0)
                    auth.format_set_cookie_header(&cookie_hdr_buf, conn.set_cookie_user_id, server.secret_key)
                else
                    null;
                const r = render.encode_followup(
                    &conn.send_buf,
                    &dashboard,
                    conn.followup_operation,
                    conn.followup_status,
                    cookie_hdr,
                );
                conn.pending_followup = false;
                conn.set_response(r.offset, r.len);
                conn.keep_alive = r.keep_alive;
            }
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

        fn mint_user_id(prng: *PRNG) u128 {
            while (true) {
                const id = prng.int(u128);
                maybe(id == 0);
                if (id != 0) return id;
            }
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
