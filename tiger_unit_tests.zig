//! Aggregated unit-test entry point — one binary that contains every
//! test block across the project. Mirrors TigerBeetle's
//! `src/unit_tests.zig` pattern.
//!
//! **Why this exists:** `zig build unit-test` runs each module's
//! tests directly in-process, which is great for dev speed but
//! leaves no binary on disk to attach kcov/perf/gdb to. This file,
//! paired with `zig build unit-test-build`, produces
//! `./zig-out/bin/tiger-unit-test` — the kcov-attachable artifact
//! the coverage pipeline (plan Phase G.0.b) needs.
//!
//! **When to update:** add a `_ = @import("X.zig");` line whenever
//! a new file gains a `test { ... }` block. The `unit_tests_aggregator_is_complete`
//! test at the bottom catches silent omissions — walks the tree and
//! asserts every test-carrying file is imported here.
//!
//! Linux-only imports are gated by `builtin.target.os.tag`. The
//! binary itself builds on both Linux and macOS; Linux-gated modules
//! contribute zero tests when cross-compiled.
//!
//! **Port note — TB quine adaptation:** TigerBeetle's
//! `src/unit_tests.zig` uses a self-updating quine: the file contains
//! its own source as a string literal and rewrites the import list
//! from a directory walk under `SNAP_UPDATE=1`. We port the
//! assertion half (walk-and-check) but not the auto-regenerate half —
//! our OS-gated import structure doesn't match TB's flat single
//! `comptime` block, so regenerating in-place is non-trivial. The
//! assertion alone closes the "silent coverage gap" failure mode
//! the TB quine exists to prevent.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Root-level app modules.
    _ = @import("app.zig");
    _ = @import("message.zig");
    _ = @import("protocol.zig");
    _ = @import("html.zig");
    // handler_test.zig excluded below — compiles against a stale
    // `route(params, body)` API that's since changed to
    // `route(method, path, body)`. Tracked follow-up to refresh.
    _ = @import("wal_test.zig");
    _ = @import("annotation_scanner.zig");
    _ = @import("supervisor.zig");

    // SQLite-backed modules.
    _ = @import("storage.zig");
    _ = @import("replay.zig");
    _ = @import("state_machine_test.zig");

    // Framework tests. framework/app.zig and framework/bench.zig
    // excluded below — they need extra build-options modules wired
    // that our aggregator doesn't currently provide. Tracked
    // follow-up: wire test_options + revisit framework/app.zig.
    _ = @import("framework/handler.zig");
    _ = @import("framework/http.zig");
    _ = @import("framework/list.zig");
    _ = @import("framework/marks.zig");
    _ = @import("framework/message_pool.zig");
    _ = @import("framework/parse.zig");
    _ = @import("framework/pending_dispatch.zig");
    _ = @import("framework/queue.zig");
    _ = @import("framework/read_only_storage.zig");
    _ = @import("framework/shm_layout.zig");
    _ = @import("framework/sse.zig");
    _ = @import("framework/time.zig");
    _ = @import("framework/auth.zig");
    _ = @import("framework/checksum.zig");

    // NOTE: framework/stdx/* files are intentionally NOT imported
    // here. tiger_unit_tests.zig has `stdx` wired as a module (via
    // build.zig's `addImport("stdx", ...)`), and Zig rejects
    // importing the same file via both a module path and a direct
    // filesystem path. Stdx tests run only when a separate test
    // target is rooted at framework/stdx/stdx.zig — tracked as a
    // follow-up below; for now stdx regressions would need to
    // surface via downstream consumers' tests.
    //
    // Trace engine + event tests (need libc).
    _ = @import("trace_event.zig");
    _ = @import("trace.zig");

    // Shell + scripts.
    _ = @import("shell.zig");
    _ = @import("scripts.zig");
    _ = @import("scripts/cfo.zig");

    // Linux-only (io_uring, unix sockets, SHM).
    if (builtin.target.os.tag == .linux) {
        _ = @import("framework/message_bus.zig");
        _ = @import("framework/io/linux.zig");
        _ = @import("framework/worker_dispatch.zig");
        _ = @import("worker_integration_test.zig");
    }
}

// --- Quine assertion ---
//
// Walks the repo, finds every `.zig` file with a `test ` line, and
// asserts each is imported somewhere in THIS file. Catches the
// silent-coverage-gap failure mode the file header warns about.
// TB's analog at `src/unit_tests.zig` uses a full self-updating
// quine; we port the assertion half only (see port note above).

const max_source_files: u32 = 8192;
const max_path_len: u32 = 256;

const skip_dirs = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    "vendor",
    "coverage",
    "docs",
    "adapters",
    "addons",
    ".focus",
    ".tiger-web",
    // Zig toolchain — vendored stdlib, ~960 .zig files not ours.
    "zig",
    // Examples + generated code carry their own tests not aggregated here.
    "examples",
    "generated",
    // TypeScript packages ship JS tests, not Zig.
    "packages",
    // Template dir is not source.
    "templates",
    // TB stdx vendored copy — we import it via `@import("stdx")` module;
    // its tests run in TB's own test suite.
    "vendored",
};

// Files with `test ` lines that are deliberately excluded from the
// aggregator: fuzz_tests.zig is its own `tiger-fuzz` binary (not a
// unit-test target), tiger_unit_tests.zig IS this file.
const excluded_files = [_][]const u8{
    "tiger_unit_tests.zig",
    "fuzz_tests.zig",
    "fuzz_lib.zig",
    // Fuzzer entry points — their tests run under tiger-fuzz, not
    // tiger-unit-test.
    "fuzz.zig",
    "replay_fuzz.zig",
    "message_bus_fuzz.zig",
    "row_format_fuzz.zig",
    "worker_dispatch_fuzz.zig",
    "codec_fuzz.zig",
    "render_fuzz.zig",
    "storage_fuzz.zig",
    "replay_fuzz.zig",
    // Simulation entry (sim.zig imports its own deps).
    "sim.zig",
    "sim_sidecar.zig",
    "sim_io.zig",
    // Benchmark files — compiled as separate binaries by build.zig.
    "aegis_checksum_benchmark.zig",
    "crc_frame_benchmark.zig",
    "hmac_session_benchmark.zig",
    "wal_parse_benchmark.zig",
    "route_match_benchmark.zig",
    "state_machine_benchmark.zig",
    // Build-script entry points.
    "build.zig",
    // stdx — wired as a module via build.zig's addImport("stdx").
    // Importing stdx files directly here conflicts with the module
    // path. Stdx tests need their own root test target (tracked
    // follow-up, not a new gap).
    "framework/stdx/stdx.zig",
    "framework/stdx/bit_set.zig",
    "framework/stdx/bounded_array.zig",
    "framework/stdx/flags.zig",
    "framework/stdx/prng.zig",
    "framework/stdx/radix.zig",
    "framework/stdx/ring_buffer.zig",
    "framework/stdx/sort_test.zig",
    "framework/stdx/stack.zig",
    "framework/stdx/time_units.zig",
    "framework/stdx/zipfian.zig",
    "framework/stdx/testing/snaptest.zig",
    // Stale — compiles against an old `route(params, body)` API that
    // no longer exists. Tracked follow-up in benchmark-tracking.md:
    // refresh handler_test.zig against the current route signature
    // then re-add here.
    "handler_test.zig",
    // Needs `test_options` build-options module wired for the
    // aggregator target. Follow-up: extend build.zig's
    // unit_test_binary config then re-add.
    "framework/bench.zig",
    // framework/app.zig has a transitive compilation issue when
    // rooted at the aggregator; the per-module test target compiles
    // it fine because it's scoped narrower. Investigate separately;
    // aggregator-level inclusion is a follow-up.
    "framework/app.zig",
};

fn should_skip_dir(name: []const u8) bool {
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn should_exclude(path: []const u8) bool {
    for (excluded_files) |excluded| {
        if (std.mem.eql(u8, path, excluded)) return true;
    }
    return false;
}

fn file_has_test_block(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !bool {
    const contents = dir.readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileTooBig => return false,
        else => return err,
    };
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "test ") or
            std.mem.startsWith(u8, trimmed, "test \""))
        {
            return true;
        }
    }
    return false;
}

test "unit_tests_aggregator_is_complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = std.fs.cwd().openDir(".", .{ .iterate = true }) catch |err| {
        std.debug.print("quine: cannot open cwd: {s}\n", .{@errorName(err)});
        return err;
    };
    defer root.close();

    // Load this file's contents once so we can substring-check imports.
    const self_contents = try root.readFileAlloc(allocator, "tiger_unit_tests.zig", 1 * 1024 * 1024);

    var walker = try root.walk(allocator);
    defer walker.deinit();

    var test_files = std.ArrayList([]const u8).init(allocator);
    var file_count: u32 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        // Skip paths that go through excluded directories.
        var path_it = std.mem.splitScalar(u8, entry.path, '/');
        var skip_this = false;
        while (path_it.next()) |component| {
            if (should_skip_dir(component)) {
                skip_this = true;
                break;
            }
        }
        if (skip_this) continue;

        // Exclude files that are intentionally not aggregated.
        if (should_exclude(entry.path)) continue;

        file_count += 1;
        try std.testing.expect(file_count <= max_source_files);

        if (try file_has_test_block(allocator, root, entry.path)) {
            try test_files.append(try allocator.dupe(u8, entry.path));
        }
    }

    // For each test-carrying file, assert `@import("<path>")` appears
    // in this file's source.
    var missing = std.ArrayList([]const u8).init(allocator);
    for (test_files.items) |path| {
        const needle = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{path});
        if (std.mem.indexOf(u8, self_contents, needle) == null) {
            try missing.append(path);
        }
    }

    if (missing.items.len > 0) {
        std.debug.print(
            "\n==========================================================\n" ++
                "Coverage-gap: {d} test-carrying file(s) are not imported\n" ++
                "in tiger_unit_tests.zig. Either add them to the\n" ++
                "`comptime {{}}` block, or add them to `excluded_files`\n" ++
                "above with a rationale comment.\n\n" ++
                "Missing imports:\n",
            .{missing.items.len},
        );
        for (missing.items) |path| std.debug.print("  - {s}\n", .{path});
        std.debug.print("==========================================================\n", .{});
        return error.AggregatorIncomplete;
    }
}
