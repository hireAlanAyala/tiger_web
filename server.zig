const std = @import("std");
const assert = std.debug.assert;
const maybe = @import("message.zig").maybe;
const message = @import("message.zig");
const schema = @import("schema.zig");
const http = @import("http.zig");
const StateMachineType = @import("state_machine.zig").StateMachineType;
const ConnectionType = @import("connection.zig").ConnectionType;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.server));

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

        pub const max_connections = 32;

        /// Per-operation timing aggregate — min/max/sum/count, same as
        /// TigerBeetle's EventTimingAggregate. Reset after each emission.
        const OperationTiming = struct {
            duration_min_ns: u64,
            duration_max_ns: u64,
            duration_sum_ns: u64,
            count: u64,
        };

        /// Array size: one slot per possible Operation integer value.
        const operation_slots = blk: {
            var max: u8 = 0;
            for (std.meta.fields(message.Operation)) |f| {
                if (f.value > max) max = f.value;
            }
            break :blk @as(usize, max) + 1;
        };

        io: *IO,
        state_machine: *StateMachine,

        listen_fd: IO.fd_t,
        accept_completion: IO.Completion,
        accepting: bool,

        connections: [max_connections]Connection,
        connections_busy: [max_connections]bool,

        tick_count: u32,
        requests_processed: u64,
        operation_timings: [operation_slots]?OperationTiming,

        /// Per-request trace logging — guarded by runtime bool.
        /// Enabled via --log-trace CLI flag. Zero cost when disabled.
        log_trace: bool,

        /// Log metrics every 10,000 ticks (~100s at 10ms/tick).
        const metrics_interval_ticks = 10_000;

        /// 30 seconds at 10ms/tick.
        pub const request_timeout_ticks = 3000;

        /// Initialize the server. Binds and listens on the given address.
        pub fn init(io: *IO, state_machine: *StateMachine, listen_fd: IO.fd_t, log_trace: bool) Server {
            var server = Server{
                .io = io,
                .state_machine = state_machine,
                .listen_fd = listen_fd,
                .accept_completion = .{},
                .accepting = false,
                .connections = undefined,
                .connections_busy = [_]bool{false} ** max_connections,
                .tick_count = 0,
                .requests_processed = 0,
                .operation_timings = [_]?OperationTiming{null} ** operation_slots,
                .log_trace = log_trace,
            };

            for (&server.connections) |*conn| {
                conn.* = Connection.init_free();
            }

            return server;
        }

        /// One tick of the server. Called from the main event loop.
        ///
        /// 1. Accept new connections if slots available
        /// 2. Process inbox: execute ready requests
        /// 3. Flush outbox: start sending responses
        /// 4. Continue receiving on connections that need more bytes
        /// 5. Close dead connections
        pub fn tick(server: *Server) void {
            server.tick_count +%= 1;
            defer server.invariants();
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
            // Scratch buffer for encoding JSON responses.
            var json_buf: [http.response_body_max]u8 = undefined;

            for (&server.connections, &server.connections_busy) |*conn, busy| {
                if (!busy) continue;
                if (conn.state != .ready) continue;

                const msg = conn.typed_message orelse unreachable;
                // Prefetch: fetch data from storage. If storage is busy
                // (transient), skip this connection — retry next tick.
                const start = std.time.Instant.now() catch unreachable;
                if (!server.state_machine.prefetch(msg)) continue;
                const resp = server.state_machine.execute(msg);
                const elapsed_ns = (std.time.Instant.now() catch unreachable).since(start);

                server.record_timing(msg.operation, elapsed_ns);

                if (server.log_trace) {
                    const duration_threshold_ns = 5 * std.time.ns_per_ms;
                    log.debug("execute: {s}: status={s} duration={d}{s} fd={d}", .{
                        @tagName(msg.operation),
                        @tagName(resp.status),
                        if (elapsed_ns < duration_threshold_ns)
                            elapsed_ns / std.time.ns_per_us
                        else
                            elapsed_ns / std.time.ns_per_ms,
                        if (elapsed_ns < duration_threshold_ns) "us" else "ms",
                        conn.fd,
                    });
                }

                const json = schema.encode_response_json(&json_buf, resp);
                conn.set_json_response(json, resp.status);
                server.requests_processed += 1;
            }
        }

        // --- Metrics ---

        /// Accumulate per-operation timing — same as TigerBeetle's
        /// Tracer.timing(): min/max/sum/count with saturating arithmetic.
        fn record_timing(server: *Server, op: message.Operation, duration_ns: u64) void {
            const slot = @intFromEnum(op);
            if (server.operation_timings[slot]) |*t| {
                t.duration_min_ns = @min(t.duration_min_ns, duration_ns);
                t.duration_max_ns = @max(t.duration_max_ns, duration_ns);
                t.duration_sum_ns +|= duration_ns;
                t.count +|= 1;
            } else {
                server.operation_timings[slot] = .{
                    .duration_min_ns = duration_ns,
                    .duration_max_ns = duration_ns,
                    .duration_sum_ns = duration_ns,
                    .count = 1,
                };
            }
        }

        fn log_metrics(server: *Server) void {
            if (server.tick_count % metrics_interval_ticks != 0) return;

            // Gauges: point-in-time connection pool snapshot.
            // Always emitted on the interval, independent of request traffic.
            var connections_active: u32 = 0;
            var connections_receiving: u32 = 0;
            var connections_ready: u32 = 0;
            var connections_sending: u32 = 0;
            for (&server.connections, server.connections_busy) |*conn, busy| {
                if (!busy) continue;
                connections_active += 1;
                switch (conn.state) {
                    .receiving => connections_receiving += 1,
                    .ready => connections_ready += 1,
                    .sending => connections_sending += 1,
                    .accepting, .closing, .free => {},
                }
            }

            log.info("gauge: connections={d}/{d} receiving={d} ready={d} sending={d}", .{
                connections_active,
                max_connections,
                connections_receiving,
                connections_ready,
                connections_sending,
            });

            // Timing aggregates: only if requests were processed.
            if (server.requests_processed == 0) return;

            log.info("metrics: requests={d} ticks={d}", .{
                server.requests_processed,
                server.tick_count,
            });

            for (&server.operation_timings, 0..) |*timing_opt, slot| {
                const t = timing_opt.* orelse continue;
                const op: message.Operation = @enumFromInt(slot);
                log.info("metrics: op={s} count={d} min={d}us max={d}us avg={d}us", .{
                    @tagName(op),
                    t.count,
                    t.duration_min_ns / std.time.ns_per_us,
                    t.duration_max_ns / std.time.ns_per_us,
                    t.duration_sum_ns / t.count / std.time.ns_per_us,
                });
                timing_opt.* = null;
            }

            server.requests_processed = 0;
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
