const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const http = @import("http.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.connection));

/// Per-connection state machine. Parameterized on IO type so the same
/// connection logic works with real epoll IO or simulated IO.
///
/// TB pattern: callbacks drive work. When a complete HTTP request is
/// parsed, the connection calls on_ready_fn to dispatch immediately.
/// When a connection closes, it calls on_close_fn to free resources.
/// The server tick does NOT scan connections for work.
pub fn ConnectionType(comptime IO: type) type {
    return struct {
        const Connection = @This();

        pub const State = enum {
            /// Slot is not in use.
            free,
            /// Accumulating request bytes.
            receiving,
            /// A complete request is in the inbox. on_ready_fn dispatches it.
            ready,
            /// The server has placed a response in the outbox, sending it.
            sending,
            /// Connection is being closed.
            closing,
        };

        state: State,
        fd: IO.fd_t,
        io: *IO,

        /// Intrusive singly-linked list for suspended connection queue.
        /// Connections with a complete request that couldn't dispatch
        /// (no free pipeline slot) are queued for retry.
        active_next: ?*Connection = null,

        /// Server callback: dispatched when a complete HTTP request
        /// is parsed. The server dispatches to the pipeline immediately.
        on_ready_fn: *const fn (*anyopaque, *Connection) void,
        /// Server callback: dispatched when a connection is closed
        /// and resources can be freed (fd closed, slot released).
        on_close_fn: *const fn (*anyopaque, *Connection) void,
        context: *anyopaque,

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


        // Whether the client wants keep-alive (HTTP/1.1 default) or close (HTTP/1.0 default).
        keep_alive: bool,

        // Whether the client sent the Datastar-Request header.
        // The render layer uses this to decide full-page HTML vs SSE fragments.
        is_datastar_request: bool,

        pub fn init(
            io: *IO,
            context: *anyopaque,
            on_ready_fn: *const fn (*anyopaque, *Connection) void,
            on_close_fn: *const fn (*anyopaque, *Connection) void,
        ) Connection {
            return .{
                .state = .free,
                .fd = 0,
                .io = io,
                .on_ready_fn = on_ready_fn,
                .on_close_fn = on_close_fn,
                .context = context,
                .recv_buf = undefined,
                .recv_pos = 0,
                .recv_completion = .{},
                .send_buf = undefined,
                .send_start = 0,
                .send_len = 0,
                .send_pos = 0,
                .send_completion = .{},
                .request_consumed = 0,
                .keep_alive = true,
                .is_datastar_request = false,
            };
        }

        /// Accept a connection. Assigns the fd and starts receiving immediately.
        pub fn on_accept(conn: *Connection, fd: IO.fd_t) void {
            assert(conn.state == .free);
            assert(fd > 0);
            defer conn.invariants();
            log.debug("connection assigned fd={d}", .{fd});
            conn.fd = fd;
            conn.state = .receiving;
            conn.recv_pos = 0;
            conn.submit_recv();
        }

        fn submit_recv(conn: *Connection) void {
            assert(conn.state == .receiving);
            assert(conn.recv_pos <= conn.recv_buf.len);
            const buf = conn.recv_buf[conn.recv_pos..];
            if (buf.len == 0) {
                conn.do_close();
                return;
            }
            conn.io.recv(conn.fd, buf, &conn.recv_completion, @ptrCast(conn), recv_callback);
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

            stdx.maybe(result <= 0);
            if (result <= 0) {
                log.mark.debug("recv: peer closed or error fd={d} result={d}", .{ conn.fd, result });
                conn.do_close();
                return;
            }

            conn.recv_pos += @intCast(result);
            assert(conn.recv_pos <= conn.recv_buf.len);

            conn.try_parse_request();

            // TB pattern: if request is ready, dispatch immediately.
            // Don't wait for the tick — the callback drives work.
            if (conn.state == .ready) {
                conn.on_ready_fn(conn.context, conn);
            } else if (conn.state == .receiving) {
                // Need more bytes — re-submit recv immediately.
                conn.submit_recv();
            }
            // .closing is handled by do_close already called above.
        }

        /// Try to parse an HTTP request from the current recv buffer.
        /// Called from recv_callback (new data arrived) and from the keep-alive
        /// path in send_callback (pipelined data may already be buffered).
        ///
        /// Pure frame detection — validates that a complete HTTP request is
        /// buffered. on_ready_fn dispatches to the pipeline immediately.
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
                .incomplete => {},
                .invalid => {
                    log.mark.warn("invalid HTTP request fd={d}", .{conn.fd});
                    conn.do_close();
                },
            }
        }


        /// Place an encoded HTTP response and send immediately.
        /// TB pattern: don't wait for tick to flush — send now.
        pub fn set_response(conn: *Connection, offset: u32, len: u32) void {
            assert(conn.state == .ready);
            conn.send_start = offset;
            conn.send_len = len;
            conn.send_pos = 0;
            conn.state = .sending;
            conn.submit_send();
        }

        /// Start sending the response. TB pattern: try synchronous
        /// send first (fast-path), only fall back to async epoll
        /// send if the socket would block. Avoids a kernel round-trip
        /// per response for small payloads that fit in the send buffer.
        /// Send the response. Called by the server after rendering.
        /// TB pattern: try synchronous send first (fast-path), only
        /// fall back to async if the socket would block.
        pub fn submit_send(conn: *Connection) void {
            assert(conn.state == .sending);
            assert(conn.send_pos < conn.send_len);

            // Fast-path: try synchronous non-blocking send.
            while (conn.send_pos < conn.send_len) {
                const abs_pos = conn.send_start + conn.send_pos;
                const abs_end = conn.send_start + conn.send_len;
                const buf = conn.send_buf[abs_pos..abs_end];
                const sent = conn.io.send_now(conn.fd, buf) orelse break;
                conn.send_pos += @intCast(sent);
            }

            if (conn.send_pos >= conn.send_len) {
                conn.send_complete();
                return;
            }

            // Slow-path: submit async send for remaining bytes.
            const abs_pos = conn.send_start + conn.send_pos;
            const abs_end = conn.send_start + conn.send_len;
            const buf = conn.send_buf[abs_pos..abs_end];
            conn.io.send(conn.fd, buf, &conn.send_completion, @ptrCast(conn), send_callback);
        }

        /// Complete a fully-sent response — shared by fast-path and callback.
        /// TB pattern: callback drives the next step immediately.
        fn send_complete(conn: *Connection) void {
            assert(conn.send_pos >= conn.send_len);
            if (!conn.keep_alive) {
                conn.do_close();
                return;
            }
            // Keep-alive: shift pipelined bytes, go back to receiving.
            assert(conn.request_consumed > 0);
            assert(conn.request_consumed <= conn.recv_pos);
            const remaining = conn.recv_pos - conn.request_consumed;
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

            // Check for pipelined request before submitting recv.
            if (conn.recv_pos > 0) {
                conn.try_parse_request();
                if (conn.state == .ready) {
                    conn.on_ready_fn(conn.context, conn);
                    return;
                }
            }
            // Need more bytes — re-submit recv.
            if (conn.state == .receiving) {
                conn.submit_recv();
            }
        }

        fn send_callback(ctx: *anyopaque, result: i32) void {
            const conn: *Connection = @ptrCast(@alignCast(ctx));
            assert(conn.state == .sending);
            defer conn.invariants();

            stdx.maybe(result <= 0);
            if (result <= 0) {
                log.mark.debug("send: error fd={d} result={d}", .{ conn.fd, result });
                conn.do_close();
                return;
            }

            conn.send_pos += @intCast(result);
            assert(conn.send_pos <= conn.send_len);

            if (conn.send_pos >= conn.send_len) {
                conn.send_complete();
            } else {
                // Partial send — re-submit immediately for remaining bytes.
                conn.submit_send();
            }
        }

        /// Close the connection: close fd, reset state, notify server.
        /// TB pattern: close happens immediately in the callback, not
        /// deferred to tick. The server's on_close_fn decrements
        /// connections_used and handles any pipeline cleanup.
        pub fn do_close(conn: *Connection) void {
            if (conn.fd > 0) {
                log.debug("closing connection fd={d}", .{conn.fd});
                conn.io.close(conn.fd);
            }
            // Reset all per-request state. Preserve IO/callback
            // fields — the connection slot is reused on next accept.
            conn.state = .free;
            conn.fd = 0;
            conn.recv_pos = 0;
            conn.recv_completion = .{};
            conn.send_completion = .{};
            conn.request_consumed = 0;
            conn.keep_alive = true;
            conn.is_datastar_request = false;
            conn.active_next = null;
            conn.on_close_fn(conn.context, conn);
        }
    };
}
