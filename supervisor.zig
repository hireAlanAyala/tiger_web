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
//!
//! Testing: the state machine (step) is unit tested below (16 tests).
//! The syscall wrappers (spawn, waitpid, kill) are NOT integration
//! tested — they're trivial one-liners delegating to std.process.Child.
//! The real socket path is exercised by developers on every run.
//! See docs/plans/message-bus.md "Phase 4.5" for the full rationale.

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
    /// Bridges IO (waitpid, kill, spawn) with the pure state machine (step).
    pub fn tick(self: *Supervisor, tick_count: u64) void {
        const child_exited = if (self.state == .running) self.wait_nonblocking() else false;
        const action = self.step(tick_count, child_exited);
        switch (action) {
            .none => {},
            .do_kill => self.do_kill(),
            .do_spawn => self.spawn() catch |err| {
                log.warn("sidecar spawn failed: {}, retrying", .{err});
                self.restart_count += 1;
                self.restart_at = tick_count + self.backoff_ticks();
            },
        }
    }

    /// Pure state machine — no IO. Takes child_exited as input (from
    /// waitpid in tick), returns the action to execute. Testable
    /// without real processes.
    ///
    /// Phase 1 (reap): child exited → schedule restart with backoff.
    /// Phase 2 (kill stuck): grace period expired → SIGKILL.
    /// Phase 3 (restart): backoff expired → spawn.
    pub const Action = enum { none, do_kill, do_spawn };

    pub fn step(self: *Supervisor, tick_count: u64, child_exited: bool) Action {
        switch (self.state) {
            .running => {
                if (child_exited) {
                    log.info("sidecar exited, will restart after backoff", .{});
                    self.state = .exited;
                    self.restart_at = tick_count + self.backoff_ticks();
                    self.kill_deadline = null;
                    return .none;
                }
                if (self.kill_deadline) |deadline| {
                    if (tick_count >= deadline) {
                        log.warn("sidecar stuck, sending SIGKILL", .{});
                        self.kill_deadline = null;
                        return .do_kill;
                    }
                }
            },
            .exited => {
                if (tick_count >= self.restart_at) {
                    return .do_spawn;
                }
            },
            .idle, .stopped => {},
        }
        return .none;
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
        const shift: u6 = @intCast(@min(self.restart_count, 7));
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

    // --- Test helpers ---

    /// Create a supervisor in .running state without spawning a real
    /// process. For state machine tests only.
    fn init_running() Supervisor {
        var sup = init(std.testing.allocator, &.{"test"});
        sup.state = .running;
        return sup;
    }
};

// =====================================================================
// Tests — exercise the pure state machine (step) without real processes.
// =====================================================================

test "backoff: exponential growth capped at max" {
    var sup = Supervisor.init_running();
    // 2^0=1, 2^1=2, 2^2=4, 2^3=8, 2^4=16, 2^5=32, 2^6=64, 2^7=100(capped)
    const expected = [_]u64{ 1, 2, 4, 8, 16, 32, 64, 100, 100 };
    for (expected) |exp| {
        try std.testing.expectEqual(exp, sup.backoff_ticks());
        sup.restart_count += 1;
    }
}

test "notify_connected resets backoff" {
    var sup = Supervisor.init_running();
    sup.restart_count = 5;
    sup.notify_connected();
    try std.testing.expectEqual(@as(u32, 0), sup.restart_count);
    try std.testing.expectEqual(@as(u64, 1), sup.backoff_ticks());
}

test "request_restart sets kill deadline" {
    var sup = Supervisor.init_running();
    sup.request_restart(100);
    try std.testing.expectEqual(@as(?u64, 100 + Supervisor.grace_ticks), sup.kill_deadline);
}

test "request_restart no-op when not running" {
    var sup = Supervisor.init(std.testing.allocator, &.{"test"});
    sup.state = .exited;
    sup.request_restart(100);
    try std.testing.expectEqual(@as(?u64, null), sup.kill_deadline);
}

test "request_restart no-op when already pending" {
    var sup = Supervisor.init_running();
    sup.request_restart(100);
    sup.request_restart(200); // should not overwrite
    try std.testing.expectEqual(@as(?u64, 100 + Supervisor.grace_ticks), sup.kill_deadline);
}

test "step: child exited → state .exited, schedule restart" {
    var sup = Supervisor.init_running();
    const action = sup.step(1000, true);
    try std.testing.expectEqual(Supervisor.Action.none, action);
    try std.testing.expectEqual(Supervisor.State.exited, sup.state);
    try std.testing.expectEqual(@as(u64, 1000 + 1), sup.restart_at); // backoff=1 (restart_count=0)
}

test "step: child still running, no deadline → none" {
    var sup = Supervisor.init_running();
    const action = sup.step(1000, false);
    try std.testing.expectEqual(Supervisor.Action.none, action);
    try std.testing.expectEqual(Supervisor.State.running, sup.state);
}

test "step: grace period expired → do_kill" {
    var sup = Supervisor.init_running();
    sup.kill_deadline = 100;
    const action = sup.step(100, false);
    try std.testing.expectEqual(Supervisor.Action.do_kill, action);
    try std.testing.expectEqual(@as(?u64, null), sup.kill_deadline);
}

test "step: grace period not expired → none" {
    var sup = Supervisor.init_running();
    sup.kill_deadline = 100;
    const action = sup.step(99, false);
    try std.testing.expectEqual(Supervisor.Action.none, action);
    try std.testing.expectEqual(@as(?u64, 100), sup.kill_deadline); // unchanged
}

test "step: exited, backoff expired → do_spawn" {
    var sup = Supervisor.init_running();
    sup.state = .exited;
    sup.restart_at = 500;
    const action = sup.step(500, false);
    try std.testing.expectEqual(Supervisor.Action.do_spawn, action);
}

test "step: exited, backoff not expired → none" {
    var sup = Supervisor.init_running();
    sup.state = .exited;
    sup.restart_at = 500;
    const action = sup.step(499, false);
    try std.testing.expectEqual(Supervisor.Action.none, action);
}

test "step: idle and stopped are no-ops" {
    var sup = Supervisor.init(std.testing.allocator, &.{"test"});
    try std.testing.expectEqual(Supervisor.Action.none, sup.step(0, false));
    sup.state = .stopped;
    try std.testing.expectEqual(Supervisor.Action.none, sup.step(0, false));
}

test "full cycle: running → exited → backoff → spawn" {
    var sup = Supervisor.init_running();

    // Child exits at tick 100.
    const a1 = sup.step(100, true);
    try std.testing.expectEqual(Supervisor.Action.none, a1);
    try std.testing.expectEqual(Supervisor.State.exited, sup.state);
    try std.testing.expectEqual(@as(u64, 101), sup.restart_at); // backoff=1

    // Tick 100: too early to restart.
    const a2 = sup.step(100, false);
    try std.testing.expectEqual(Supervisor.Action.none, a2);

    // Tick 101: backoff expired → spawn.
    const a3 = sup.step(101, false);
    try std.testing.expectEqual(Supervisor.Action.do_spawn, a3);
}

test "full cycle: request_restart → grace period → kill" {
    var sup = Supervisor.init_running();

    // Server disconnects sidecar at tick 200.
    sup.request_restart(200);
    try std.testing.expectEqual(@as(?u64, 250), sup.kill_deadline);

    // Tick 249: not yet.
    const a1 = sup.step(249, false);
    try std.testing.expectEqual(Supervisor.Action.none, a1);

    // Tick 250: grace period expired → kill.
    const a2 = sup.step(250, false);
    try std.testing.expectEqual(Supervisor.Action.do_kill, a2);

    // If child exits after kill (next reap).
    const a3 = sup.step(251, true);
    try std.testing.expectEqual(Supervisor.Action.none, a3);
    try std.testing.expectEqual(Supervisor.State.exited, sup.state);
}

test "backoff increases across consecutive crashes" {
    var sup = Supervisor.init_running();

    // Crash 1: backoff = 1.
    _ = sup.step(0, true);
    try std.testing.expectEqual(@as(u64, 1), sup.restart_at);

    // Simulate spawn succeeded → running again.
    sup.state = .running;
    sup.restart_count += 1;

    // Crash 2: backoff = 2.
    _ = sup.step(10, true);
    try std.testing.expectEqual(@as(u64, 12), sup.restart_at);

    sup.state = .running;
    sup.restart_count += 1;

    // Crash 3: backoff = 4.
    _ = sup.step(20, true);
    try std.testing.expectEqual(@as(u64, 24), sup.restart_at);
}

test "notify_connected resets backoff after recovery" {
    var sup = Supervisor.init_running();
    sup.restart_count = 5; // accumulated from crashes

    // Sidecar reconnected successfully.
    sup.notify_connected();
    try std.testing.expectEqual(@as(u32, 0), sup.restart_count);

    // Next crash gets fresh backoff (1, not 32).
    _ = sup.step(100, true);
    try std.testing.expectEqual(@as(u64, 101), sup.restart_at); // backoff=1
}
