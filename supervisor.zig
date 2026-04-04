//! Sidecar process supervisor — spawn, monitor, restart.
//!
//! Owns N sidecar child processes. The server owns the connections.
//! Neither knows the other exists. main.zig (composition root) wires
//! them by reading public state from both:
//!
//!   server.sidecar_any_ready() == false → supervisor.request_restart()
//!   server.sidecar_any_ready() == true  → supervisor.notify_connected()
//!
//! TB pattern (Vortex LoggedProcess): std.process.Child for spawn,
//! waitpid(WNOHANG) for non-blocking reap, no signal handlers.
//!
//! Testing: the state machine (step) is unit tested below.
//! The syscall wrappers (spawn, waitpid, kill) are trivial one-liners.
//! See docs/plans/message-bus.md "Phase 4.5" for the full rationale.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const log = std.log.scoped(.supervisor);

pub const Supervisor = struct {
    processes: []Process,
    argv: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, argv: []const []const u8, count: u8) !Supervisor {
        assert(count >= 1);
        const processes = try allocator.alloc(Process, count);
        for (processes) |*p| p.* = Process.init();
        return .{
            .processes = processes,
            .argv = argv,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Supervisor) void {
        self.allocator.free(self.processes);
    }

    /// Spawn all processes.
    pub fn spawn_all(self: *Supervisor) !void {
        for (self.processes) |*p| try p.spawn(self.argv, self.allocator);
    }

    /// One tick — reap, kill stuck, restart for all processes.
    pub fn tick(self: *Supervisor, tick_count: u64) void {
        for (self.processes) |*p| p.tick(tick_count, self.argv, self.allocator);
    }

    /// Reset backoff for all processes. Called by main.zig when
    /// a sidecar completes the READY handshake.
    pub fn notify_connected(self: *Supervisor) void {
        for (self.processes) |*p| p.notify_connected();
    }

    /// Graceful shutdown of all processes.
    pub fn shutdown(self: *Supervisor) void {
        for (self.processes) |*p| p.shutdown();
    }
};

/// Per-process state. One sidecar child process.
pub const Process = struct {
    child: ?std.process.Child,
    state: State,

    // Restart backoff.
    restart_at: u64,
    restart_count: u32,


    pub const State = enum {
        idle,
        running,
        exited,
        stopped,
    };

    const max_backoff_ticks: u64 = 100;

    pub fn init() Process {
        return .{
            .child = null,
            .state = .idle,
            .restart_at = 0,
            .restart_count = 0,
        };
    }

    pub fn spawn(self: *Process, argv: []const []const u8, allocator: std.mem.Allocator) !void {
        assert(self.state == .idle or self.state == .exited);

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        // New process group — kill(-pgid) kills the entire tree
        // (npx → node → tsx → handler). Prevents orphaned processes.
        child.pgid = 0; // 0 = child's PID becomes the group ID

        try child.spawn();

        log.info("spawned sidecar pid={d}", .{child.id});
        self.child = child;
        self.state = .running;
    }

    /// One tick. Bridges IO with the pure state machine (step).
    pub fn tick(self: *Process, tick_count: u64, argv: []const []const u8, allocator: std.mem.Allocator) void {
        const child_exited = if (self.state == .running) self.wait_nonblocking() else false;
        const action = self.step(tick_count, child_exited);
        switch (action) {
            .none => {},
            .do_spawn => self.spawn(argv, allocator) catch |err| {
                log.warn("sidecar spawn failed: {}, retrying", .{err});
                self.restart_count += 1;
                self.restart_at = tick_count + self.backoff_ticks();
            },
        }
    }

    /// Pure state machine — no IO. Testable without real processes.
    /// Phase 1 (reap): child exited → schedule restart with backoff.
    /// Phase 2 (restart): backoff expired → spawn.
    /// No kill phase — the sidecar detects the closed socket and
    /// exits on its own. The supervisor just watches via waitpid.
    pub const Action = enum { none, do_spawn };

    pub fn step(self: *Process, tick_count: u64, child_exited: bool) Action {
        switch (self.state) {
            .running => {
                if (child_exited) {
                    log.info("sidecar exited, will restart after backoff", .{});
                    self.state = .exited;
                    self.restart_at = tick_count + self.backoff_ticks();
                    return .none;
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

    pub fn notify_connected(self: *Process) void {
        self.restart_count = 0;
    }

    pub fn shutdown(self: *Process) void {
        if (self.state != .running) {
            self.state = .stopped;
            return;
        }
        if (self.child) |*child| {
            log.info("shutting down sidecar pid={d}", .{child.id});
            // Kill the entire process group — not just the direct child.
            // npx spawns node → tsx → handler. Killing only the direct
            // child (npx) leaves grandchildren orphaned.
            // Negate PID to kill process group (POSIX: kill(-pgid, sig))
            const pgid: posix.pid_t = -child.id;
            _ = posix.kill(pgid, posix.SIG.TERM) catch {};
            _ = child.wait() catch {};
        }
        self.child = null;
        self.state = .stopped;
    }

    // --- Private ---

    fn backoff_ticks(self: *const Process) u64 {
        const shift: u6 = @intCast(@min(self.restart_count, 7));
        return @min(@as(u64, 1) << shift, max_backoff_ticks);
    }

    fn wait_nonblocking(self: *Process) bool {
        assert(self.state == .running);
        const child = &(self.child.?);
        const result = posix.waitpid(child.id, posix.W.NOHANG);
        if (result.pid == 0) return false;
        self.child = null;
        return true;
    }

    /// Create a Process in .running state without spawning a real
    /// process. For state machine tests only.
    fn init_running() Process {
        var p = init();
        p.state = .running;
        return p;
    }
};

// =====================================================================
// Tests — exercise the pure state machine (step) without real processes.
// =====================================================================

test "backoff: exponential growth capped at max" {
    var p = Process.init_running();
    const expected = [_]u64{ 1, 2, 4, 8, 16, 32, 64, 100, 100 };
    for (expected) |exp| {
        try std.testing.expectEqual(exp, p.backoff_ticks());
        p.restart_count += 1;
    }
}

test "notify_connected resets backoff" {
    var p = Process.init_running();
    p.restart_count = 5;
    p.notify_connected();
    try std.testing.expectEqual(@as(u32, 0), p.restart_count);
    try std.testing.expectEqual(@as(u64, 1), p.backoff_ticks());
}

test "step: child exited → state .exited, schedule restart" {
    var p = Process.init_running();
    const action = p.step(1000, true);
    try std.testing.expectEqual(Process.Action.none, action);
    try std.testing.expectEqual(Process.State.exited, p.state);
    try std.testing.expectEqual(@as(u64, 1000 + 1), p.restart_at);
}

test "step: child still running, no deadline → none" {
    var p = Process.init_running();
    const action = p.step(1000, false);
    try std.testing.expectEqual(Process.Action.none, action);
    try std.testing.expectEqual(Process.State.running, p.state);
}

test "step: exited, backoff expired → do_spawn" {
    var p = Process.init_running();
    p.state = .exited;
    p.restart_at = 500;
    const action = p.step(500, false);
    try std.testing.expectEqual(Process.Action.do_spawn, action);
}

test "step: exited, backoff not expired → none" {
    var p = Process.init_running();
    p.state = .exited;
    p.restart_at = 500;
    const action = p.step(499, false);
    try std.testing.expectEqual(Process.Action.none, action);
}

test "step: idle and stopped are no-ops" {
    var p = Process.init();
    try std.testing.expectEqual(Process.Action.none, p.step(0, false));
    p.state = .stopped;
    try std.testing.expectEqual(Process.Action.none, p.step(0, false));
}

test "full cycle: running → exited → backoff → spawn" {
    var p = Process.init_running();

    const a1 = p.step(100, true);
    try std.testing.expectEqual(Process.Action.none, a1);
    try std.testing.expectEqual(Process.State.exited, p.state);
    try std.testing.expectEqual(@as(u64, 101), p.restart_at);

    const a2 = p.step(100, false);
    try std.testing.expectEqual(Process.Action.none, a2);

    const a3 = p.step(101, false);
    try std.testing.expectEqual(Process.Action.do_spawn, a3);
}

test "backoff increases across consecutive crashes" {
    var p = Process.init_running();

    _ = p.step(0, true);
    try std.testing.expectEqual(@as(u64, 1), p.restart_at);

    p.state = .running;
    p.restart_count += 1;

    _ = p.step(10, true);
    try std.testing.expectEqual(@as(u64, 12), p.restart_at);

    p.state = .running;
    p.restart_count += 1;

    _ = p.step(20, true);
    try std.testing.expectEqual(@as(u64, 24), p.restart_at);
}

test "notify_connected resets backoff after recovery" {
    var p = Process.init_running();
    p.restart_count = 5;

    p.notify_connected();
    try std.testing.expectEqual(@as(u32, 0), p.restart_count);

    _ = p.step(100, true);
    try std.testing.expectEqual(@as(u64, 101), p.restart_at);
}
