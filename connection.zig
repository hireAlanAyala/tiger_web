const std = @import("std");
const assert = std.debug.assert;
const maybe = @import("message.zig").maybe;
const message = @import("message.zig");
const http = @import("http.zig");
const codec = @import("codec.zig");
const auth = @import("auth.zig");
const Time = @import("time.zig").Time;
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
        time: Time,

        // Receive buffer: accumulate incoming HTTP bytes until a full request arrives.
        recv_buf: [http.recv_buf_max]u8,
        recv_pos: u32,
        recv_completion: IO.Completion,

        // Send buffer: holds the HTTP response being sent.
        send_buf: [http.send_buf_max]u8,
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

        // Inbox: filled by recv callback when a complete request is parsed.
        typed_message: ?message.Message,


        pub fn init_free(time: Time) Connection {
            return .{
                .state = .free,
                .fd = 0,
                .time = time,
                .recv_buf = undefined,
                .recv_pos = 0,
                .recv_completion = .{},
                .send_buf = undefined,
                .send_len = 0,
                .send_pos = 0,
                .send_completion = .{},
                .request_consumed = 0,
                .last_activity_tick = 0,
                .recv_activity = false,
                .send_activity = false,
                .keep_alive = true,
                .typed_message = null,
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
                    assert(conn.typed_message == null);
                    assert(conn.recv_completion.operation == .none);
                    assert(conn.send_completion.operation == .none);
                },
                .accepting => {
                    assert(conn.fd == 0);
                    assert(conn.typed_message == null);
                },
                .receiving => {
                    assert(conn.fd > 0);
                    assert(conn.typed_message == null);
                    assert(conn.recv_pos <= conn.recv_buf.len);
                },
                .ready => {
                    assert(conn.fd > 0);
                    assert(conn.typed_message != null);
                    assert(conn.request_consumed > 0);
                    assert(conn.request_consumed <= conn.recv_pos);
                },
                .sending => {
                    assert(conn.fd > 0);
                    assert(conn.typed_message == null);
                    assert(conn.send_len > 0);
                    assert(conn.send_len <= conn.send_buf.len);
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
            maybe(result <= 0);
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
        fn try_parse_request(conn: *Connection) void {
            assert(conn.state == .receiving);
            switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
                .complete => |parsed| {
                    assert(parsed.total_len > 0);
                    assert(parsed.total_len <= conn.recv_pos);
                    conn.keep_alive = parsed.keep_alive;

                    // OPTIONS preflight — respond with CORS headers directly.
                    // No auth required for preflight.
                    if (parsed.method == .options) {
                        const encoded = http.encode_options_response(&conn.send_buf);
                        conn.send_len = @intCast(encoded.len);
                        conn.send_pos = 0;
                        conn.request_consumed = parsed.total_len;
                        conn.typed_message = null;
                        conn.state = .sending;
                        return;
                    }

                    // Auth gate — verify bearer token before routing.
                    const token = parsed.authorization orelse {
                        log.mark.warn("auth: missing token fd={d}", .{conn.fd});
                        conn.send_401(parsed.total_len);
                        return;
                    };
                    if (auth.verify(token, conn.time.realtime()) == null) {
                        log.mark.warn("auth: invalid token fd={d}", .{conn.fd});
                        conn.send_401(parsed.total_len);
                        return;
                    }

                    // Route through codec layer.
                    if (codec.translate(parsed.method, parsed.path, parsed.body)) |msg| {
                        conn.typed_message = msg;
                        conn.request_consumed = parsed.total_len;
                        conn.state = .ready;
                        return;
                    }

                    log.mark.warn("unmapped request fd={d}", .{conn.fd});
                    conn.state = .closing;
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

        /// Send a 401 Unauthorized response directly, bypassing the state machine.
        /// Same pattern as OPTIONS preflight — a connection-level shortcut.
        fn send_401(conn: *Connection, consumed: u32) void {
            assert(conn.state == .receiving);
            const encoded = http.encode_401_response(&conn.send_buf);
            conn.send_len = @intCast(encoded.len);
            conn.send_pos = 0;
            conn.request_consumed = consumed;
            conn.typed_message = null;
            conn.state = .sending;
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

        /// Called by the server tick after execute. Encodes the JSON response into the send buffer.
        pub fn set_json_response(conn: *Connection, json_body: []const u8, status: message.Status) void {
            assert(conn.state == .ready);
            assert(conn.typed_message != null);
            defer conn.invariants();
            const encoded = http.encode_json_response(&conn.send_buf, status, json_body);
            conn.send_len = @intCast(encoded.len);
            conn.send_pos = 0;
            conn.typed_message = null;
            conn.state = .sending;
        }

        /// Start sending the response.
        pub fn submit_send(conn: *Connection, io: *IO) void {
            assert(conn.state == .sending);
            assert(conn.send_pos < conn.send_len);
            const buf = conn.send_buf[conn.send_pos..conn.send_len];
            io.send(conn.fd, buf, &conn.send_completion, @ptrCast(conn), send_callback);
        }

        fn send_callback(ctx: *anyopaque, result: i32) void {
            const conn: *Connection = @ptrCast(@alignCast(ctx));
            assert(conn.state == .sending);
            defer conn.invariants();
            // Peer may close or error at any time.
            maybe(result <= 0);
            if (result <= 0) {
                log.mark.debug("send: error fd={d} result={d}", .{ conn.fd, result });
                conn.state = .closing;
                return;
            }

            conn.send_pos += @intCast(result);
            assert(conn.send_pos <= conn.send_len);
            conn.send_activity = true;

            // Partial sends are expected — TCP may accept fewer bytes than requested.
            maybe(conn.send_pos < conn.send_len);

            if (conn.send_pos >= conn.send_len) {
                // Fully sent.
                // Client may or may not want keep-alive.
                maybe(conn.keep_alive);
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
                maybe(remaining > 0);
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
