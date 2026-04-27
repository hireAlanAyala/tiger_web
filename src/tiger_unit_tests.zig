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
    _ = @import("wal_test.zig");
    _ = @import("annotation_scanner.zig");
    _ = @import("supervisor.zig");

    // SQLite-backed modules.
    _ = @import("storage.zig");
    _ = @import("replay.zig");
    _ = @import("state_machine_test.zig");

    // Framework tests.
    _ = @import("framework/app.zig");
    _ = @import("framework/bench.zig");
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

    // tidy.zig (TB src/tidy.zig port at 8977868dd) is intentionally
    // NOT imported here. The architectural file is in place — it's
    // the discipline-as-tests primitive that should eventually
    // replace scripts/style_check.zig — but the codebase has 1001
    // accumulated violations across 100 files (long lines, defer
    // newlines, banned patterns, dead code, type-function naming).
    // Wiring tidy into the aggregator now would block all CI red
    // until cleanup converges (~days of focused work). Run tidy
    // standalone via `zig build tidy` for incremental cleanup; add
    // `_ = @import("tidy.zig");` here once `zig build tidy` returns
    // green. Tracked as a follow-up in
    // `docs/plans/benchmark-tracking.md`.

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
    "coverage",
    "docs",
    "adapters",
    "addons",
    ".focus",
    ".tiger-web",
    // Zig toolchain — vendored stdlib, ~960 .zig files not ours.
    "zig",
    // Examples carry their own tests not aggregated here.
    "examples",
    // Vendored / generated under src/ are name-matched anywhere
    // in the path; this catches src/vendor/, src/generated/,
    // src/framework/stdx/vendored/.
    "vendor",
    "generated",
    "vendored",
    // TypeScript packages ship JS tests, not Zig.
    "packages",
    // Template dir is not source.
    "templates",
};

// Files with `test ` lines that are deliberately excluded from the
// aggregator: fuzz_tests.zig is its own `tiger-fuzz` binary (not a
// unit-test target), tiger_unit_tests.zig IS this file.
const excluded_files = [_][]const u8{
    "src/tiger_unit_tests.zig",
    "src/fuzz_tests.zig",
    "src/fuzz_lib.zig",
    // Fuzzer entry points — their tests run under tiger-fuzz, not
    // tiger-unit-test.
    "src/fuzz.zig",
    "src/replay_fuzz.zig",
    "src/message_bus_fuzz.zig",
    "src/row_format_fuzz.zig",
    "src/worker_dispatch_fuzz.zig",
    // Simulation entry (sim.zig imports its own deps).
    "src/sim.zig",
    "src/sim_sidecar.zig",
    "src/sim_io.zig",
    // Benchmark files — compiled as separate binaries by build.zig.
    "src/aegis_checksum_benchmark.zig",
    "src/crc_frame_benchmark.zig",
    "src/hmac_session_benchmark.zig",
    "src/wal_parse_benchmark.zig",
    "src/route_match_benchmark.zig",
    "src/state_machine_benchmark.zig",
    // Build-script entry points.
    "build.zig",
    // stdx — wired as a module via build.zig's addImport("stdx").
    // Importing stdx files directly here conflicts with the module
    // path. Stdx tests need their own root test target (tracked
    // follow-up, not a new gap).
    "src/framework/stdx/stdx.zig",
    "src/framework/stdx/bit_set.zig",
    "src/framework/stdx/bounded_array.zig",
    "src/framework/stdx/flags.zig",
    "src/framework/stdx/prng.zig",
    "src/framework/stdx/radix.zig",
    "src/framework/stdx/ring_buffer.zig",
    "src/framework/stdx/sort_test.zig",
    "src/framework/stdx/stack.zig",
    "src/framework/stdx/time_units.zig",
    "src/framework/stdx/zipfian.zig",
    "src/framework/stdx/testing/snaptest.zig",
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
    const self_contents = try root.readFileAlloc(allocator, "src/tiger_unit_tests.zig", 1 * 1024 * 1024);

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
    // in this file's source. The @import strings are relative to this
    // file's directory (src/), so strip the leading "src/" from the
    // walker-collected path before building the needle.
    var missing = std.ArrayList([]const u8).init(allocator);
    for (test_files.items) |path| {
        const import_path = if (std.mem.startsWith(u8, path, "src/"))
            path["src/".len..]
        else
            path;
        const needle = try std.fmt.allocPrint(allocator, "@import(\"{s}\")", .{import_path});
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
