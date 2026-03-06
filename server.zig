const std = @import("std");
const assert = std.debug.assert;
const maybe = @import("message.zig").maybe;
const message = @import("message.zig");
const StateMachine = @import("state_machine.zig").StateMachine;
const ConnectionType = @import("connection.zig").ConnectionType;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.server));

/// The server orchestrator, parameterized on the IO type.
/// In production, IO is the real epoll-based implementation.
/// In simulation, IO is SimIO with deterministic behavior.
///
/// This is the equivalent of TigerBeetle's Replica — it owns all connections,
/// drives the tick loop, and mediates between network IO and the state machine.
// Takes IO as an arg so it can be mocked by the sim.
pub fn ServerType(comptime IO: type) type {
    const Connection = ConnectionType(IO);

    return struct {
        const Server = @This();

        pub const max_connections = 32;

        io: *IO,
        state_machine: *StateMachine,

        listen_fd: IO.fd_t,
        accept_completion: IO.Completion,
        accepting: bool,

        connections: [max_connections]Connection,
        connections_busy: [max_connections]bool,

        tick_count: u32,

        /// 30 seconds at 10ms/tick.
        pub const request_timeout_ticks = 3000;

        /// Initialize the server. Binds and listens on the given address.
        pub fn init(io: *IO, state_machine: *StateMachine, listen_fd: IO.fd_t) Server {
            var server = Server{
                .io = io,
                .state_machine = state_machine,
                .listen_fd = listen_fd,
                .accept_completion = .{},
                .accepting = false,
                .connections = undefined,
                .connections_busy = [_]bool{false} ** max_connections,
                .tick_count = 0,
            };

            for (&server.connections) |*conn| {
                conn.* = Connection.init_free();
            }

            return server;
        }

        /// One tick of the server. Called from the main event loop.
        ///
        /// 1. Accept new connections if slots available
        /// 2. Process inbox: run prefetch/execute for ready requests
        /// 3. Flush outbox: start sending responses
        /// 4. Continue receiving on connections that need more bytes
        /// 5. Close dead connections
        pub fn tick(server: *Server) void {
            server.tick_count +%= 1;
            defer server.invariants();
            server.maybe_accept();
            server.process_inbox();
            server.flush_outbox();
            server.continue_receives();
            server.update_activity();
            server.timeout_idle();
            server.close_dead();
        }

        // --- Accept ---

        fn maybe_accept(server: *Server) void {
            if (server.accepting) return;

            // All slots may be busy under load.
            const slot = server.acquire_slot() orelse return;
            server.connections[slot].set_accepting();
            server.connections_busy[slot] = true;
            server.accepting = true;

            server.io.accept(
                server.listen_fd,
                &server.accept_completion,
                @ptrCast(server),
                accept_callback,
            );
        }

        fn accept_callback(ctx: *anyopaque, result: i32) void {
            const server: *Server = @ptrCast(@alignCast(ctx));
            server.accepting = false;

            // Find the connection in accepting state — must exist if accepting was true.
            const slot = server.find_accepting_slot() orelse unreachable;

            // Accept may fail due to resource exhaustion or client abort.
            maybe(result < 0);
            if (result < 0) {
                log.mark.warn("accept failed: result={d}", .{result});
                server.connections[slot].on_accept_error();
                server.connections_busy[slot] = false;
                return;
            }

            server.connections[slot].on_accept(server.io, result, server.tick_count);
            log.debug("accepted connection fd={d} slot={d}", .{ result, slot });
        }

        // --- Inbox: process ready requests ---

        fn process_inbox(server: *Server) void {
            for (&server.connections, &server.connections_busy) |*conn, busy| {
                if (!busy) continue;
                if (conn.state != .ready) continue;

                const req = conn.request orelse unreachable;

                // Two-phase: prefetch then execute.
                const prefetched = server.state_machine.prefetch(req.key);
                const resp = server.state_machine.execute(
                    req.header.operation,
                    req.key,
                    req.value,
                    prefetched,
                );

                // Place response in outbox.
                conn.set_response(resp.header.status, resp.value);
            }
        }

        // --- Outbox: send pending responses ---

        fn flush_outbox(server: *Server) void {
            for (&server.connections, &server.connections_busy) |*conn, busy| {
                if (!busy) continue;
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
            for (&server.connections, &server.connections_busy) |*conn, busy| {
                if (!busy) continue;
                conn.continue_recv(server.io);
            }
        }

        // --- Close dead connections ---

        fn close_dead(server: *Server) void {
            for (&server.connections, &server.connections_busy) |*conn, *busy| {
                if (!busy.*) continue;
                if (conn.state != .closing) continue;
                assert(conn.fd > 0);

                log.debug("closing connection fd={d}", .{conn.fd});
                server.io.close(conn.fd);
                conn.* = Connection.init_free();
                busy.* = false;
            }
        }

        // --- Activity tracking ---

        /// Update last_activity_tick for connections that signaled activity via callbacks.
        fn update_activity(server: *Server) void {
            for (&server.connections, &server.connections_busy) |*conn, busy| {
                if (!busy) continue;
                if (conn.recv_activity or conn.send_activity) {
                    conn.last_activity_tick = server.tick_count;
                    conn.recv_activity = false;
                    conn.send_activity = false;
                }
            }
        }

        // --- Timeout idle connections ---

        fn timeout_idle(server: *Server) void {
            for (&server.connections, &server.connections_busy) |*conn, busy| {
                if (!busy) continue;
                if (conn.state == .free or conn.state == .accepting or conn.state == .closing) continue;
                if (conn.check_timeout(server.tick_count, request_timeout_ticks)) {
                    log.mark.debug("connection timed out fd={d}", .{conn.fd});
                    conn.state = .closing;
                }
            }
        }

        // --- Slot management ---

        fn acquire_slot(server: *Server) ?usize {
            for (server.connections_busy, 0..) |busy, i| {
                if (!busy) {
                    assert(server.connections[i].state == .free);
                    return i;
                }
            }
            return null;
        }

        fn find_accepting_slot(server: *Server) ?usize {
            for (&server.connections, server.connections_busy, 0..) |*conn, busy, i| {
                if (busy and conn.state == .accepting) return i;
            }
            return null;
        }

        /// Cross-check structural invariants after every tick.
        /// Connection-level invariants are checked by Connection.invariants().
        /// Server checks cross-connection invariants: busy/state agreement and accept count.
        fn invariants(server: *Server) void {
            var accepting_count: u32 = 0;

            for (&server.connections, server.connections_busy) |*conn, busy| {
                // busy and state must agree.
                if (!busy) {
                    assert(conn.state == .free);
                } else {
                    assert(conn.state != .free);
                }

                // Per-connection internal consistency.
                conn.invariants();

                if (conn.state == .accepting) accepting_count += 1;
            }

            // At most one connection can be in accepting state.
            assert(accepting_count <= 1);
            if (server.accepting) {
                assert(accepting_count == 1);
            }
        }
    };
}
