const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx/stdx.zig");
const http = @import("http.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.connection));

/// Per-connection state machine. Parameterized on IO type so the same
/// connection logic works with real epoll IO or simulated IO.
///
/// IO callbacks only update buffers and set state. They never call into
/// the application state machine — that's the server tick's job.
pub fn ConnectionType(comptime IO: type) type {
    return struct {
        const Connection = @This();

        pub const State = enum {
            /// Slot is not in use.
            free,
            /// Waiting for the accept to complete (fd not yet assigned).
            accepting,
            /// Accumulating request bytes.
            receiving,
            /// A complete request is in the inbox, waiting for the server tick.
            ready,
            /// The server has placed a response in the outbox, sending it.
            sending,
            /// Connection is being closed.
            closing,
        };

        state: State,
        fd: IO.fd_t,

        // Receive buffer: accumulate incoming HTTP bytes until a full request arrives.
        recv_buf: [http.recv_buf_max]u8,
        recv_pos: u32,
        recv_completion: IO.Completion,

        // Send buffer: holds the HTTP response being sent.
        send_buf: [http.send_buf_max]u8,
        send_start: u32,
        send_len: u32,
        send_pos: u32,
        send_completion: IO.Completion,

        // How many bytes the parsed HTTP request consumed from recv_buf.
        // Used to shift leftover bytes for keep-alive pipelining.
        request_consumed: u32,

        // Tick-based timeout: tracks when the connection last had activity.
        last_activity_tick: u32,
        // Set by callbacks to signal the server to update last_activity_tick.
        recv_activity: bool,
        send_activity: bool,

        // Whether the client wants keep-alive (HTTP/1.1 default) or close (HTTP/1.0 default).
        keep_alive: bool,

        // Whether the client sent the Datastar-Request header.
        // The render layer uses this to decide full-page HTML vs SSE fragments.
        is_datastar_request: bool,

        pub fn init_free() Connection {
            return .{
                .state = .free,
                .fd = 0,
                .recv_buf = undefined,
                .recv_pos = 0,
                .recv_completion = .{},
                .send_buf = undefined,
                .send_start = 0,
                .send_len = 0,
                .send_pos = 0,
                .send_completion = .{},
                .request_consumed = 0,
                .last_activity_tick = 0,
                .recv_activity = false,
                .send_activity = false,
                .keep_alive = true,
                .is_datastar_request = false,
            };
        }

        /// Transition to accepting state. The server calls this when it
        /// acquires a slot and submits an accept.
        pub fn set_accepting(conn: *Connection) void {
            assert(conn.state == .free);
            conn.state = .accepting;
        }

        /// Called by the accept callback. Assigns the fd and starts receiving.
        pub fn on_accept(conn: *Connection, io: *IO, fd: IO.fd_t, current_tick: u32) void {
            assert(conn.state == .accepting);
            assert(fd > 0);
            defer conn.invariants();
            log.debug("connection assigned fd={d}", .{fd});
            conn.fd = fd;
            conn.state = .receiving;
            conn.recv_pos = 0;
            conn.last_activity_tick = current_tick;
            conn.submit_recv(io);
        }

        /// Called when the accept fails.
        pub fn on_accept_error(conn: *Connection) void {
            assert(conn.state == .accepting);
            conn.state = .free;
        }

        fn submit_recv(conn: *Connection, io: *IO) void {
            assert(conn.state == .receiving);
            assert(conn.recv_pos <= conn.recv_buf.len);
            const buf = conn.recv_buf[conn.recv_pos..];
            if (buf.len == 0) {
                // Buffer full but no valid request — close.
                conn.state = .closing;
                return;
            }
            io.recv(conn.fd, buf, &conn.recv_completion, @ptrCast(conn), recv_callback);
        }

        /// Cross-check internal state consistency.
        pub fn invariants(conn: *const Connection) void {
            switch (conn.state) {
                .free => {
                    assert(conn.fd == 0);
                    assert(conn.recv_completion.operation == .none);
                    assert(conn.send_completion.operation == .none);
                    assert(!conn.is_datastar_request);
                },
                .accepting => {
                    assert(conn.fd == 0);
                },
                .receiving => {
                    assert(conn.fd > 0);
                    assert(conn.recv_pos <= conn.recv_buf.len);
                },
                .ready => {
                    assert(conn.fd > 0);
                    assert(conn.request_consumed > 0);
                    assert(conn.request_consumed <= conn.recv_pos);
                },
                .sending => {
                    assert(conn.fd > 0);
                    assert(conn.send_len > 0);
                    assert(conn.send_start + conn.send_len <= conn.send_buf.len);
                    assert(conn.send_pos <= conn.send_len);
                },
                .closing => {
                    assert(conn.fd > 0);
                },
            }
        }

        fn recv_callback(ctx: *anyopaque, result: i32) void {
            const conn: *Connection = @ptrCast(@alignCast(ctx));
            assert(conn.state == .receiving);
            defer conn.invariants();
            // Peer may close or error at any time.
            stdx.maybe(result <= 0);
            if (result <= 0) {
                log.mark.debug("recv: peer closed or error fd={d} result={d}", .{ conn.fd, result });
                conn.state = .closing;
                return;
            }

            conn.recv_pos += @intCast(result);
            assert(conn.recv_pos <= conn.recv_buf.len);
            conn.recv_activity = true;

            conn.try_parse_request();
        }

        /// Try to parse an HTTP request from the current recv buffer.
        /// Called from recv_callback (new data arrived) and from the keep-alive
        /// path in send_callback (pipelined data may already be buffered).
        ///
        /// Pure frame detection — validates that a complete HTTP request is
        /// buffered. Application logic (auth, routing) runs in the server tick.
        fn try_parse_request(conn: *Connection) void {
            assert(conn.state == .receiving);
            switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                .complete => |parsed| {
                    assert(parsed.total_len > 0);
                    assert(parsed.total_len <= conn.recv_pos);
                    conn.request_consumed = parsed.total_len;
                    conn.keep_alive = parsed.keep_alive;
                    conn.state = .ready;
                },
                .incomplete => {
                    // Need more bytes — stay in receiving state.
                },
                .invalid => {
                    log.mark.warn("invalid HTTP request fd={d}", .{conn.fd});
                    conn.state = .closing;
                },
            }
        }

        /// Returns true if the connection has been idle for longer than timeout_ticks.
        pub fn check_timeout(conn: *Connection, current_tick: u32, timeout_ticks: u32) bool {
            return current_tick -% conn.last_activity_tick > timeout_ticks;
        }

        /// Called by the server tick to continue receiving if we need more bytes.
        pub fn continue_recv(conn: *Connection, io: *IO) void {
            if (conn.state != .receiving) return;
            // Don't re-submit if a recv is already in-flight.
            if (conn.recv_completion.operation != .none) return;
            conn.submit_recv(io);
        }

        /// Called by the server tick to place an encoded HTTP response in the
        /// send buffer. The server encodes the response; the connection is
        /// pure byte mechanics.
        pub fn set_response(conn: *Connection, offset: u32, len: u32) void {
            assert(conn.state == .ready);
            defer conn.invariants();
            conn.send_start = offset;
            conn.send_len = len;
            conn.send_pos = 0;
            conn.state = .sending;
        }

        /// Start sending the response.
        pub fn submit_send(conn: *Connection, io: *IO) void {
            assert(conn.state == .sending);
            assert(conn.send_pos < conn.send_len);
            const abs_pos = conn.send_start + conn.send_pos;
            const abs_end = conn.send_start + conn.send_len;
            const buf = conn.send_buf[abs_pos..abs_end];
            io.send(conn.fd, buf, &conn.send_completion, @ptrCast(conn), send_callback);
        }

        fn send_callback(ctx: *anyopaque, result: i32) void {
            const conn: *Connection = @ptrCast(@alignCast(ctx));
            assert(conn.state == .sending);
            defer conn.invariants();
            // Peer may close or error at any time.
            stdx.maybe(result <= 0);
            if (result <= 0) {
                log.mark.debug("send: error fd={d} result={d}", .{ conn.fd, result });
                conn.state = .closing;
                return;
            }

            conn.send_pos += @intCast(result);
            assert(conn.send_pos <= conn.send_len);
            conn.send_activity = true;

            // Partial sends are expected — TCP may accept fewer bytes than requested.
            stdx.maybe(conn.send_pos < conn.send_len);

            if (conn.send_pos >= conn.send_len) {
                // Fully sent.
                // Client may or may not want keep-alive.
                stdx.maybe(conn.keep_alive);
                if (!conn.keep_alive) {
                    // HTTP/1.0 or Connection: close — close the connection.
                    conn.state = .closing;
                    return;
                }
                // Keep-alive: go back to receiving.
                // Shift any leftover bytes (pipelined next request) to the front.
                assert(conn.request_consumed > 0);
                assert(conn.request_consumed <= conn.recv_pos);
                const remaining = conn.recv_pos - conn.request_consumed;
                // Pipelined data may or may not be present.
                stdx.maybe(remaining > 0);
                if (remaining > 0) {
                    std.mem.copyForwards(
                        u8,
                        conn.recv_buf[0..remaining],
                        conn.recv_buf[conn.request_consumed..conn.recv_pos],
                    );
                }
                conn.recv_pos = @intCast(remaining);
                assert(conn.recv_pos <= conn.recv_buf.len);
                conn.request_consumed = 0;
                conn.is_datastar_request = false;
                conn.state = .receiving;

                // Try to parse pipelined data immediately. If a complete
                // request is already buffered, go to .ready without waiting
                // for another recv callback.
                if (conn.recv_pos > 0) {
                    conn.try_parse_request();
                }
                // If still .receiving, server tick will submit a recv.
            }
            // If partially sent, stay in sending state.
            // Server tick will call submit_send again.
        }
    };
}
