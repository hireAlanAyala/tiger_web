//! Focus CLI — single Zig binary for project scaffolding, build, and dev.
//!
//! Replaces the shell scripts (focus, focus-internal). All tooling
//! centralized in Zig per TB's principle: "Bash is not cross platform,
//! suffers from high accidental complexity, and is a second language."
//!
//! Subcommands:
//!   new --ts <name>    Scaffold a TypeScript project
//!   build <path>       Scan annotations + generate dispatch
//!   dev <path>         Build + server + sidecar + watch + reload
//!   schema <args>      Apply/reset database schema
//!   docs               Print framework reference
//!
//! Build configuration:
//!   focus is compiled with sidecar_enabled=true (separate build_options in
//!   build.zig). This is intentional — focus always embeds a sidecar-mode server.
//!   The tiger-web binary uses the user's -Dsidecar flag. Two binaries, two roles,
//!   two compile-time configurations. Same pattern as TB's replica vs benchmark.

const std = @import("std");
const stdx = @import("stdx");
const scanner = @import("annotation_scanner.zig");
const server_main = @import("main.zig");
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .log_level = .debug, // compile all levels; filter at runtime
    .logFn = server_main.log_runtime,
};

const CLIArgs = union(enum) {
    new: NewArgs,
    build: BuildArgs,
    dev: DevArgs,

    pub const help =
        \\Usage:
        \\  focus new --ts <name>                          Scaffold a TypeScript project
        \\  focus build <path>                             Scan annotations + generate dispatch
        \\  focus dev [--port=N] [--timeout=N] <path>      Build + server + sidecar + watch + reload
        \\
    ;
};

const NewArgs = struct {
    ts: bool = false,
    // go: bool = false,  // future
    // py: bool = false,  // future
    /// Positional: project name
    @"--": void,
    name: []const u8,
};

const BuildArgs = struct {
    /// Positional: handler source path
    @"--": void,
    path: []const u8,
};

const DevArgs = struct {
    /// Server port (0 = random).
    port: u16 = 0,
    /// Exit after this many seconds (for CI/testing). 0 = run forever.
    timeout: u32 = 0,
    /// Positional: handler source path
    @"--": void,
    path: []const u8,
};

const stderr = std.io.getStdErr().writer();

/// Whether to emit ANSI color codes (false when piped).
var use_color: bool = true;

fn init_color() void {
    use_color = std.posix.isatty(std.io.getStdOut().handle);
}

fn color(code: []const u8) []const u8 {
    return if (use_color) code else "";
}

pub fn main() !void {
    init_color();

    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa_allocator.deinit()) {
        .ok => {},
        .leak => @panic("memory leak"),
    };
    const gpa = gpa_allocator.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    const cli = stdx.flags(&args, CLIArgs);

    switch (cli) {
        .new => |new_args| try cmd_new(new_args),
        .build => |build_args| try cmd_build(gpa, build_args),
        .dev => |dev_args| try cmd_dev(gpa, dev_args),
    }
}

// =============================================================
// focus new
// =============================================================

fn cmd_new(args: NewArgs) !void {
    if (!args.ts) {
        stderr.print("error: specify a language: --ts\n", .{}) catch {};
        std.process.exit(1);
    }

    const name = args.name;
    const stdout = std.io.getStdOut().writer();

    // Create project directory.
    std.fs.cwd().makeDir(name) catch |err| {
        if (err == error.PathAlreadyExists) {
            stderr.print("error: '{s}' already exists.\n", .{name}) catch {};
            std.process.exit(1);
        }
        return err;
    };

    // Write template files. No framework code — that lives in the "focus" npm package.
    const templates = .{
        .{ "schema.sql", @embedFile("templates/ts/schema.sql") },
        .{ ".focus", @embedFile("templates/ts/dot-focus") },
        .{ ".gitignore", @embedFile("templates/ts/dot-gitignore") },
        .{ "package.json", @embedFile("templates/ts/package.json") },
        .{ "tsconfig.json", @embedFile("templates/ts/tsconfig.json") },
        .{ "src/list_items.ts", @embedFile("templates/ts/src/list_items.ts") },
        .{ "src/create_item.ts", @embedFile("templates/ts/src/create_item.ts") },
    };

    const dir = try std.fs.cwd().openDir(name, .{});
    dir.makeDir("src") catch {};
    // focus/ directory is created by `focus build` for generated output only.

    inline for (templates) |t| {
        const path = t[0];
        const content = t[1];
        if (std.mem.indexOfScalar(u8, path, '/')) |_| {
            // Has subdirectory — already created above.
        }
        const file = try dir.createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }


    try stdout.print(
        \\
        \\  Created {s}/
        \\
        \\  Next steps:
        \\    cd {s}
        \\    focus dev src/
        \\
        \\
    , .{ name, name });
}

// =============================================================
// focus build
// =============================================================

fn cmd_build(gpa: std.mem.Allocator, args: BuildArgs) !void {
    const path = args.path;
    const stdout = std.io.getStdOut().writer();

    // Ensure the focus package is extracted to node_modules/focus/.
    // The binary bundles the package — no npm install needed.
    ensure_package();

    // Arena for scanner (allocates freely, freed after scan completes).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read and parse .focus file.
    const dot_focus = read_dot_focus(allocator) orelse std.process.exit(1);
    const build_hook = parse_hook(dot_focus, "build") orelse {
        stderr.print("error: .focus file missing 'build' hook\n", .{}) catch {};
        std.process.exit(1);
    };

    // Ensure focus/ directory exists for generated output.
    std.fs.cwd().makeDir("focus") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Step 1: Run the annotation scanner (linked in-process — no subprocess).
    try scanner.scan(allocator, .{
        .scan_dir = path,
        .manifest_path = "focus/manifest.json",
        .registry_path = "focus/operations.json",
        .operations_zig_path = "focus/operations.generated.zig",
        .routes_zig_path = "focus/routes.generated.zig",
    });

    // Step 2: Run the user's build hook (from .focus file).
    try run_cmd(allocator, &.{ "sh", "-c", build_hook });

    try stdout.print("Build complete.\n", .{});
}

// =============================================================
// focus dev
// =============================================================

fn cmd_dev(gpa: std.mem.Allocator, args: DevArgs) !void {
    const path = args.path;
    const stdout = std.io.getStdOut().writer();

    // Deadline: if --timeout=N, exit after N seconds (for CI/testing).
    const deadline: ?i128 = if (args.timeout > 0)
        std.time.nanoTimestamp() + @as(i128, args.timeout) * std.time.ns_per_s
    else
        null;

    // Read .focus hooks.
    const dot_focus = std.fs.cwd().readFileAlloc(gpa, ".focus", 4096) catch {
        stderr.print("error: no .focus file — run 'focus new' first\n", .{}) catch {};
        std.process.exit(1);
    };
    defer gpa.free(dot_focus);
    const start_hook = parse_hook(dot_focus, "start") orelse {
        stderr.print("error: .focus file missing 'start' hook\n", .{}) catch {};
        std.process.exit(1);
    };
    const db_name = parse_hook(dot_focus, "db") orelse "tiger_web.db";

    // Step 1: Build (scanner + codegen).
    try cmd_build(gpa, .{ .path = path, .@"--" = {} });

    // Step 2: Apply schema if schema.sql exists.
    if (std.fs.cwd().access("schema.sql", .{})) |_| {
        apply_schema(db_name);
    } else |_| {}

    // Step 3: Start server in a background thread (embedded, same process).
    // PID-scoped socket path avoids collisions between concurrent focus dev sessions.
    const server_pid = std.os.linux.getpid();
    var sock_path_buf: [64]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&sock_path_buf, "/tmp/focus-dev-{d}.sock", .{server_pid}) catch unreachable;

    // Atomic port signal: server thread stores after bind, we load after SHM ready.
    var port_signal = std.atomic.Value(u16).init(0);

    const db_z = to_sentinel(db_name);

    const server_config = ServerConfig{
        .port = args.port,
        .sock_path = sock_path,
        .db = &db_z,
        .port_signal = &port_signal,
    };
    const server_thread = try std.Thread.spawn(.{}, run_server, .{&server_config});
    _ = server_thread; // detached — runs until process exits

    // Compute SHM name from server PID.
    var shm_buf: [32]u8 = undefined;
    const shm_name = std.fmt.bufPrint(&shm_buf, "tiger-{d}", .{server_pid}) catch unreachable;

    // Wait for SHM to appear.
    try stdout.print("{s}[server]{s}  starting...\n", .{ color("\x1b[36m"), color("\x1b[0m") });
    var ready = false;
    for (0..100) |_| {
        var shm_path_buf: [64]u8 = undefined;
        const shm_path = std.fmt.bufPrint(&shm_path_buf, "/dev/shm/{s}", .{shm_name}) catch unreachable;
        if (std.fs.cwd().access(shm_path, .{})) |_| {
            ready = true;
            break;
        } else |_| {}
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    if (!ready) {
        stderr.print("error: server did not start (no SHM region after 5s)\n", .{}) catch {};
        std.process.exit(1);
    }

    // Read actual port from server thread (guaranteed written before SHM create).
    const actual_port = port_signal.load(.acquire);

    // Step 4: Start sidecar.
    // Bake $SHM and $SOCK into the shell command prefix so the child inherits
    // the full parent environment (PATH, HOME, etc.) plus our two variables.
    var start_cmd_buf: [1024]u8 = undefined;
    const start_cmd = std.fmt.bufPrint(&start_cmd_buf, "export SHM={s} SOCK={s}; {s}", .{
        shm_name, sock_path, start_hook,
    }) catch {
        stderr.print("error: start hook too long\n", .{}) catch {};
        std.process.exit(1);
    };

    var sidecar = SidecarChild.spawn(gpa, &.{ "sh", "-c", start_cmd }) catch |err| {
        stderr.print("error: failed to start sidecar: {}\n", .{err}) catch {};
        std.process.exit(1);
    };

    // Install SIGINT/SIGTERM handler for clean shutdown.
    install_signal_handlers();

    // Track schema.sql mtime — detect changes, advise restart.
    var schema_mtime: i128 = get_file_mtime("schema.sql");

    try stdout.print(
        \\
        \\  {s}Focus running on http://localhost:{d}{s}
        \\  Watching {s} for changes...
        \\
        \\
    , .{ color("\x1b[1m"), actual_port, color("\x1b[0m"), path });

    // Step 5: Watch + reload loop.
    // Linux: inotify (kernel events, instant detection, recursive).
    // macOS: stat polling (walks subdirs naturally).
    var watcher = try FileWatcher.init(gpa, path);

    while (true) {
        // Check for signal-based shutdown (Ctrl-C).
        if (shutdown_requested.load(.acquire)) {
            try stdout.print("\n{s}[dev]{s}     shutting down...\n", .{ color("\x1b[36m"), color("\x1b[0m") });
            sidecar.kill();
            return;
        }

        // Check if sidecar crashed. Rate-limit restarts to avoid spin loops.
        if (sidecar.check_exited()) |exit_code| {
            try stdout.print("{s}[watch]{s}   sidecar exited (code {d}) — restarting...\n", .{
                color("\x1b[33m"), color("\x1b[0m"), exit_code,
            });
            sidecar = try SidecarChild.spawn(gpa, &.{ "sh", "-c", start_cmd });
        }

        // Compute poll timeout: 1s intervals (re-check signals, sidecar, deadline).
        const poll_ms: i32 = if (deadline) |dl| blk: {
            const remaining_ns = dl - std.time.nanoTimestamp();
            if (remaining_ns <= 0) {
                try stdout.print("{s}[dev]{s}     timeout reached, shutting down\n", .{ color("\x1b[36m"), color("\x1b[0m") });
                sidecar.kill();
                return;
            }
            const remaining_ms: i32 = @intCast(@min(@divFloor(remaining_ns, std.time.ns_per_ms), 1000));
            break :blk remaining_ms;
        } else 1000;

        if (!watcher.wait(poll_ms)) {
            // No source file change — check schema.sql separately.
            // Schema changes can't be hot-applied (server caches prepared statements,
            // ALTER TABLE would trigger SQLITE_SCHEMA errors). Warn and advise restart.
            const new_schema_mtime = get_file_mtime("schema.sql");
            if (new_schema_mtime != schema_mtime and new_schema_mtime != 0) {
                schema_mtime = new_schema_mtime;
                try stdout.print("{s}[watch]{s}   schema.sql changed — restart focus dev to apply\n", .{ color("\x1b[33m"), color("\x1b[0m") });
            }
            continue;
        }

        try stdout.print("{s}[watch]{s}   change detected, rebuilding...\n", .{ color("\x1b[33m"), color("\x1b[0m") });

        // Rebuild.
        cmd_build(gpa, .{ .path = path, .@"--" = {} }) catch {
            try stdout.print("{s}[watch]{s}   build failed — sidecar not restarted\n", .{ color("\x1b[33m"), color("\x1b[0m") });
            continue;
        };

        // Restart sidecar.
        sidecar.kill();
        std.time.sleep(500 * std.time.ns_per_ms); // bus deadline
        sidecar = try SidecarChild.spawn(gpa, &.{ "sh", "-c", start_cmd });
        try stdout.print("{s}[watch]{s}   sidecar restarted\n", .{ color("\x1b[33m"), color("\x1b[0m") });
    }
}

// =============================================================
// .focus file parsing
// =============================================================

/// Read .focus file from cwd. Returns null and prints error on failure.
fn read_dot_focus(allocator: std.mem.Allocator) ?[]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, ".focus", 4096) catch {
        stderr.print("error: no .focus file — run 'focus new' or create one with:\n  build = <your build command>\n  start = <your sidecar command>\n", .{}) catch {};
        return null;
    };
}

/// Parse a hook value from .focus file content.
/// Format: "key = value" (one per line). Lines starting with # are comments.
/// Trailing whitespace stripped. Key matching is exact (won't match "builder" for "build").
fn parse_hook(content: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        // Strip trailing \r (Windows line endings).
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (line.len == 0) continue;
        if (line[0] == '#') continue; // comment line

        if (std.mem.startsWith(u8, line, key)) {
            const rest = line[key.len..];
            // Match "key = value" or "key=value".
            const value = if (rest.len > 2 and rest[0] == ' ' and rest[1] == '=' and rest[2] == ' ')
                rest[3..]
            else if (rest.len > 0 and rest[0] == '=')
                rest[1..]
            else
                continue; // not a match (e.g. "builder" when looking for "build")

            // Strip trailing whitespace.
            const trimmed = std.mem.trimRight(u8, value, " \t");
            if (trimmed.len == 0) continue;
            return trimmed;
        }
    }
    return null;
}

// =============================================================
// Package extraction — binary bundles the focus TS package
// =============================================================

/// Embedded package files — extracted to node_modules/focus/ on first run.
/// The binary IS the distribution: no npm install, no registry, no version skew.
const package_files = .{
    .{ "node_modules/focus/package.json", @embedFile("packages/ts/package.json") },
    .{ "node_modules/focus/src/index.ts", @embedFile("packages/ts/src/index.ts") },
    .{ "node_modules/focus/src/types.ts", @embedFile("packages/ts/src/types.ts") },
    .{ "node_modules/focus/src/serde.ts", @embedFile("packages/ts/src/serde.ts") },
    .{ "node_modules/focus/src/routing.ts", @embedFile("packages/ts/src/routing.ts") },
    .{ "node_modules/focus/src/sidecar.ts", @embedFile("packages/ts/src/sidecar.ts") },
    .{ "node_modules/focus/src/shm_client.ts", @embedFile("packages/ts/src/shm_client.ts") },
    .{ "node_modules/focus/src/codegen.ts", @embedFile("packages/ts/src/codegen.ts") },
    .{ "node_modules/focus/src/protocol_generated.ts", @embedFile("packages/ts/src/protocol_generated.ts") },
    .{ "node_modules/focus/src/bin/focus-sidecar.ts", @embedFile("packages/ts/src/bin/focus-sidecar.ts") },
    .{ "node_modules/focus/src/bin/focus-codegen.ts", @embedFile("packages/ts/src/bin/focus-codegen.ts") },
    .{ "node_modules/focus/native/shm.node", @embedFile("addons/shm/shm.node") },
};

/// Extract the embedded focus package to node_modules/focus/ if missing or stale.
/// Called at the start of cmd_build — before codegen needs the package.
fn ensure_package() void {
    const cwd = std.fs.cwd();

    // Check if package already exists and is current version.
    if (cwd.access("node_modules/focus/package.json", .{})) |_| {
        // Package exists. Check if it matches the embedded version.
        // For now: always overwrite. The extraction is fast (<1ms for ~100KB)
        // and guarantees the package matches the binary. No stale risk.
    } else |_| {}

    // Create directory structure.
    cwd.makePath("node_modules/focus/src/bin") catch {};
    cwd.makePath("node_modules/focus/native") catch {};

    // Write all embedded files.
    inline for (package_files) |entry| {
        const path = entry[0];
        const content = entry[1];
        const file = cwd.createFile(path, .{}) catch |err| {
            stderr.print("error: failed to write {s}: {}\n", .{ path, err }) catch {};
            return;
        };
        defer file.close();
        file.writeAll(content) catch {};
    }

    // Make bin entry points executable (npm does this on install, we extract manually).
    const bins = [_][]const u8{
        "node_modules/focus/src/bin/focus-codegen.ts",
        "node_modules/focus/src/bin/focus-sidecar.ts",
    };
    for (bins) |bin_path| {
        const f = cwd.openFile(bin_path, .{}) catch continue;
        defer f.close();
        f.chmod(0o755) catch {};
    }

    // Create bin symlinks (npm creates these on install, we extract manually).
    cwd.makePath("node_modules/.bin") catch {};
    cwd.deleteFile("node_modules/.bin/focus-codegen") catch {};
    cwd.deleteFile("node_modules/.bin/focus-sidecar") catch {};
    cwd.symLink("../focus/src/bin/focus-codegen.ts", "node_modules/.bin/focus-codegen", .{}) catch {};
    cwd.symLink("../focus/src/bin/focus-sidecar.ts", "node_modules/.bin/focus-sidecar", .{}) catch {};
}

// =============================================================
// SidecarChild — lifecycle-tracked child process
// =============================================================

/// Wraps std.process.Child with explicit lifecycle tracking.
/// States: .running (pid valid) or .exited (already reaped).
/// Prevents double-wait and kill-after-reap bugs.
const SidecarChild = struct {
    child: std.process.Child,
    state: State,
    last_spawn: i128,

    const State = enum { running, exited };

    fn spawn(allocator: std.mem.Allocator, argv: []const []const u8) !SidecarChild {
        var child = std.process.Child.init(argv, allocator);
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        try child.spawn();
        return .{
            .child = child,
            .state = .running,
            .last_spawn = std.time.nanoTimestamp(),
        };
    }

    /// Non-blocking check: has the process exited?
    /// Returns exit code if exited (first time only), null if still running.
    /// Enforces 5s backoff — returns null if called too soon after last spawn.
    fn check_exited(self: *SidecarChild) ?u32 {
        if (self.state == .exited) return null; // already reported

        // Backoff: don't report exit within 5s of spawn (prevents spin loops
        // when the start hook has a persistent failure like missing binary).
        const elapsed = std.time.nanoTimestamp() - self.last_spawn;
        if (elapsed < 5 * std.time.ns_per_s) return null;

        const result = std.posix.waitpid(self.child.id, std.os.linux.W.NOHANG);
        if (result.pid != 0) {
            self.state = .exited;
            return @as(u32, @intCast((result.status & 0xff00) >> 8));
        }
        return null;
    }

    /// Kill the process and wait for exit. Safe to call in any state.
    fn kill(self: *SidecarChild) void {
        if (self.state == .exited) return;
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        self.state = .exited;
    }
};

// =============================================================
// Process helpers
// =============================================================

/// Run a command, wait for exit. Errors exit the process.
fn run_cmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    if (term.Exited != 0) {
        stderr.print("command failed (exit {d})\n", .{term.Exited}) catch {};
        std.process.exit(1);
    }
}

// =============================================================
// Signal handling — clean shutdown on Ctrl-C
//
// Uses std.atomic.Value(bool) from a signal handler. On Linux/x86/ARM,
// atomic store is a single aligned write instruction — async-signal-safe
// by hardware guarantee. The POSIX sig_atomic_t concern applies to C's
// volatile semantics, not to hardware atomic instructions. Zig's
// @atomicStore compiles to an atomic instruction, which is safe.
// =============================================================

var shutdown_requested = std.atomic.Value(bool).init(false);

fn install_signal_handlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = signal_handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn signal_handler(_: c_int) callconv(.C) void {
    shutdown_requested.store(true, .release);
}

// =============================================================
// Server config + thread
// =============================================================

const ServerConfig = struct {
    port: u16,
    sock_path: []const u8,
    db: *const [128]u8, // sentinel-terminated buffer (see to_sentinel)
    port_signal: *std.atomic.Value(u16),
};

/// Run the server in a background thread.
fn run_server(config: *const ServerConfig) void {
    // Find the null terminator in the fixed buffer to get a [:0] slice.
    const db_bytes = config.db;
    const len = std.mem.indexOfScalar(u8, db_bytes, 0) orelse db_bytes.len;
    const db_z: [:0]const u8 = db_bytes[0..len :0];

    server_main.server_run(std.heap.page_allocator, .{
        .port = config.port,
        .db = db_z,
        .sidecar = config.sock_path,
        .port_signal = config.port_signal,
        .quiet = true,
    }) catch |err| {
        stderr.print("{s}[server]{s}  fatal: {}\n", .{ color("\x1b[31m"), color("\x1b[0m"), err }) catch {};
        std.process.exit(1);
    };
}

/// Apply a schema SQL file to a database (same process, no subprocess).
fn apply_schema(db_name: []const u8) void {
    const buf = to_sentinel(db_name);
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    const db_z: [:0]const u8 = buf[0..len :0];
    server_main.cmd_schema(.{
        .db = db_z,
        .action = "apply",
        .file = "schema.sql",
        .@"--" = {},
    });
}

/// Convert a runtime []const u8 to a null-terminated fixed buffer.
/// The inherent awkwardness: SQLite's C API needs null-terminated strings,
/// Zig slices don't carry terminators. This is the conversion boundary.
fn to_sentinel(s: []const u8) [128]u8 {
    var buf: [128]u8 = .{0} ** 128;
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    return buf;
}

// =============================================================
// File watcher — inotify (Linux) or stat polling (macOS)
// =============================================================

const FileWatcher = struct {
    inotify_fd: if (builtin.os.tag == .linux) i32 else void,
    path: []const u8,
    last_mtime: i128,

    fn init(gpa: std.mem.Allocator, path: []const u8) !FileWatcher {
        if (builtin.os.tag == .linux) {
            const fd = try std.posix.inotify_init1(0); // blocking

            // Watch the directory and all subdirectories recursively.
            const real_path = std.fs.cwd().realpathAlloc(gpa, path) catch null;
            defer if (real_path) |rp| gpa.free(rp);
            const watch_root = real_path orelse path;

            try add_watches_recursive(fd, gpa, watch_root);

            return .{ .inotify_fd = fd, .path = path, .last_mtime = 0 };
        } else {
            // macOS: no inotify. Use stat polling (walks subdirs naturally).
            return .{ .inotify_fd = {}, .path = path, .last_mtime = get_dir_mtime(path) catch 0 };
        }
    }

    /// Wait for a file change. Returns true if a change was detected,
    /// false if the timeout expired without a change.
    fn wait(self: *FileWatcher, timeout_ms: i32) bool {
        if (builtin.os.tag == .linux) {
            // Poll the inotify fd with a timeout.
            var fds = [_]std.posix.pollfd{.{
                .fd = self.inotify_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const n = std.posix.poll(&fds, timeout_ms) catch return false;
            if (n == 0) return false; // timeout
            // Drain the inotify event buffer and check for new directories.
            self.drain_and_update_watches();
            // Brief pause to coalesce rapid saves (editor write + rename).
            std.time.sleep(200 * std.time.ns_per_ms);
            return true;
        } else {
            // macOS: poll every second, up to timeout.
            const iterations: u32 = if (timeout_ms < 0) std.math.maxInt(u32) else @intCast(@divTrunc(@as(u32, @intCast(timeout_ms)), 1000) + 1);
            for (0..iterations) |_| {
                std.time.sleep(1 * std.time.ns_per_s);
                const new_mtime = get_dir_mtime(self.path) catch continue;
                if (new_mtime != self.last_mtime) {
                    self.last_mtime = new_mtime;
                    return true;
                }
            }
            return false;
        }
    }

    /// Drain inotify events. If any IN_CREATE events for directories appear,
    /// add new watches (handles mkdir src/subdir/ during dev).
    fn drain_and_update_watches(self: *FileWatcher) void {
        if (builtin.os.tag != .linux) return;
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (true) {
            const len = std.posix.read(self.inotify_fd, &buf) catch break;
            if (len == 0) break;

            // Parse events to detect IN_CREATE|IN_ISDIR.
            var offset: usize = 0;
            while (offset < len) {
                const event: *const std.os.linux.inotify_event = @alignCast(@ptrCast(&buf[offset]));
                if (event.mask & std.os.linux.IN.CREATE != 0 and event.mask & std.os.linux.IN.ISDIR != 0) {
                    // New directory created — add a watch.
                    if (event.getName()) |name| {
                        var path_buf: [512]u8 = undefined;
                        if (std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ self.path, name })) |sub_path| {
                            _ = std.posix.inotify_add_watch(
                                self.inotify_fd,
                                sub_path,
                                std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE,
                            ) catch {};
                        } else |_| {}
                    }
                }
                offset += @sizeOf(std.os.linux.inotify_event) + event.len;
            }

            // Non-blocking: check if more events available.
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = self.inotify_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&poll_fds, 0) catch break;
            if (ready == 0) break;
        }
    }
};

/// Recursively add inotify watches on a directory and all subdirectories.
fn add_watches_recursive(fd: i32, gpa: std.mem.Allocator, root: []const u8) !void {
    // Watch the root directory itself.
    const root_z = try gpa.dupeZ(u8, root);
    defer gpa.free(root_z);
    _ = try std.posix.inotify_add_watch(
        fd,
        root_z,
        std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE,
    );

    // Walk subdirectories.
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const sub_path = std.fmt.allocPrintZ(gpa, "{s}/{s}", .{ root, entry.path }) catch continue;
        defer gpa.free(sub_path);
        _ = std.posix.inotify_add_watch(
            fd,
            sub_path,
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE,
        ) catch continue;
    }
}

/// Get the most recent mtime of any source file in a directory (recursive).
fn get_dir_mtime(path: []const u8) !i128 {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    var max_mtime: i128 = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(entry.path) catch continue;
        const mtime = stat.mtime;
        if (mtime > max_mtime) max_mtime = mtime;
    }
    return max_mtime;
}

/// Get mtime of a single file (0 if not found).
fn get_file_mtime(path: []const u8) i128 {
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.mtime;
}
