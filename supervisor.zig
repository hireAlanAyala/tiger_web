//! Sidecar process supervisor — spawn, monitor, restart.
//!
//! Owns the sidecar child process. The server owns the connection.
//! Neither knows the other exists. main.zig (composition root) wires
//! them by reading public state from both:
//!
//!   server.sidecar_connected == false → supervisor.request_restart()
//!   server.sidecar_connected == true  → supervisor.notify_connected()
//!
//! TB pattern (Vortex LoggedProcess): std.process.Child for spawn,
//! waitpid(WNOHANG) for non-blocking reap, no signal handlers.
//!
//! Stage 1: single sidecar. Stage 2 generalizes for N processes.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const log = std.log.scoped(.supervisor);

pub const Supervisor = struct {
    child: ?std.process.Child,
    state: State,
    allocator: std.mem.Allocator,

    // Restart backoff.
    restart_at: u64,
    restart_count: u32,

    // Grace period for stuck process kill.
    // Set by request_restart(). If the process hasn't exited by
    // this tick, SIGKILL it. null = no pending kill.
    kill_deadline: ?u64,

    // Configuration.
    argv: []const []const u8,

    pub const State = enum {
        idle, // not started
        running, // child alive
        exited, // child exited, pending restart
        stopped, // explicitly stopped (shutdown)
    };

    /// Grace period: ticks between request_restart and SIGKILL.
    /// 500ms at 10ms/tick. Gives the sidecar time to detect the
    /// closed socket and exit cleanly.
    const grace_ticks: u64 = 50;

    /// Maximum restart delay. 1s at 10ms/tick.
    const max_backoff_ticks: u64 = 100;

    pub fn init(allocator: std.mem.Allocator, argv: []const []const u8) Supervisor {
        return .{
            .child = null,
            .state = .idle,
            .allocator = allocator,
            .restart_at = 0,
            .restart_count = 0,
            .kill_deadline = null,
            .argv = argv,
        };
    }

    /// Spawn the sidecar child process. TB's LoggedProcess pattern:
    /// init Child, set stdio behaviors, spawn.
    pub fn spawn(self: *Supervisor) !void {
        assert(self.state == .idle or self.state == .exited);

        var child = std.process.Child.init(self.argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        log.info("spawned sidecar pid={d}", .{child.id});
        self.child = child;
        self.state = .running;
        self.kill_deadline = null;
    }

    /// One tick of the supervisor. Called from main.zig after server.tick().
    ///
    /// Phase 1 (reap): check if child exited. Schedule restart with backoff.
    /// Phase 2 (kill stuck): if grace period expired, SIGKILL.
    /// Phase 3 (restart): if backoff expired, spawn.
    pub fn tick(self: *Supervisor, tick_count: u64) void {
        switch (self.state) {
            .running => {
                // Phase 1: reap.
                if (self.wait_nonblocking()) {
                    log.info("sidecar exited, will restart after backoff", .{});
                    self.state = .exited;
                    self.restart_at = tick_count + self.backoff_ticks();
                    self.kill_deadline = null;
                    return;
                }
                // Phase 2: kill stuck (grace period expired).
                if (self.kill_deadline) |deadline| {
                    if (tick_count >= deadline) {
                        log.warn("sidecar stuck, sending SIGKILL", .{});
                        self.do_kill();
                        self.kill_deadline = null;
                    }
                }
            },
            .exited => {
                // Phase 3: restart after backoff.
                if (tick_count >= self.restart_at) {
                    self.spawn() catch |err| {
                        log.warn("sidecar spawn failed: {}, retrying", .{err});
                        self.restart_count += 1;
                        self.restart_at = tick_count + self.backoff_ticks();
                    };
                }
            },
            .idle, .stopped => {},
        }
    }

    /// Signal that a restart is needed. Called by main.zig when
    /// server.sidecar_connected transitions from true to false.
    /// Sets a kill deadline — if the process doesn't exit on its
    /// own within grace_ticks (after detecting the closed socket),
    /// the supervisor kills it.
    pub fn request_restart(self: *Supervisor, tick_count: u64) void {
        if (self.state != .running) return;
        if (self.kill_deadline != null) return; // already pending
        self.kill_deadline = tick_count + grace_ticks;
    }

    /// Reset backoff. Called by main.zig when server.sidecar_connected
    /// transitions from false to true (READY handshake completed).
    /// A sidecar that connected successfully was healthy — future
    /// crashes get fresh backoff.
    pub fn notify_connected(self: *Supervisor) void {
        self.restart_count = 0;
    }

    /// Graceful shutdown. SIGTERM, wait for exit, then mark stopped.
    /// Called from main.zig on server shutdown.
    pub fn shutdown(self: *Supervisor) void {
        if (self.state != .running) {
            self.state = .stopped;
            return;
        }
        if (self.child) |*child| {
            log.info("shutting down sidecar pid={d}", .{child.id});
            _ = posix.kill(child.id, posix.SIG.TERM) catch {};
            _ = child.wait() catch {};
        }
        self.child = null;
        self.state = .stopped;
    }

    // --- Private ---

    /// Exponential backoff: min(2^restart_count, max_backoff_ticks).
    fn backoff_ticks(self: *const Supervisor) u64 {
        const shift: u6 = @intCast(@min(self.restart_count, 6));
        return @min(@as(u64, 1) << shift, max_backoff_ticks);
    }

    /// Non-blocking child reap. Returns true if child exited.
    /// TB's LoggedProcess.wait_nonblocking pattern.
    /// Caller guarantees state == .running → child != null (pair
    /// assertion with spawn which sets both).
    fn wait_nonblocking(self: *Supervisor) bool {
        assert(self.state == .running);
        const child = &(self.child.?); // spawn guarantees non-null
        const result = posix.waitpid(child.id, posix.W.NOHANG);
        if (result.pid == 0) return false; // still running
        self.child = null;
        return true;
    }

    /// Send SIGKILL to the child process.
    /// Caller guarantees state == .running → child != null.
    fn do_kill(self: *Supervisor) void {
        assert(self.state == .running);
        const child = self.child.?;
        log.warn("killing sidecar pid={d}", .{child.id});
        _ = posix.kill(child.id, posix.SIG.KILL) catch {};
    }
};
