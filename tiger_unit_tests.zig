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
//! a new file gains a `test { ... }` block. Forgetting is a silent
//! coverage gap — the per-module `unit-test` step still runs X's
//! tests, but `tiger-unit-test` doesn't include them, so the
//! coverage report misses them.
//!
//! Linux-only imports are gated by `builtin.target.os.tag`. The
//! binary itself builds on both Linux and macOS; Linux-gated modules
//! contribute zero tests when cross-compiled.

const builtin = @import("builtin");

comptime {
    // Always-available (pure Zig, no syscalls that differ per-OS).
    _ = @import("message.zig");
    _ = @import("framework/message_pool.zig");
    _ = @import("wal_test.zig");
    _ = @import("annotation_scanner.zig");
    _ = @import("supervisor.zig");

    // SQLite-backed modules.
    _ = @import("storage.zig");
    _ = @import("replay.zig");
    _ = @import("state_machine_test.zig");

    // Framework tests.
    _ = @import("framework/http.zig");
    _ = @import("framework/marks.zig");
    _ = @import("framework/time.zig");
    _ = @import("framework/auth.zig");
    _ = @import("framework/checksum.zig");
    _ = @import("framework/parse.zig");

    // Trace engine + event tests (need libc).
    _ = @import("trace_event.zig");
    _ = @import("trace.zig");

    // Shell + scripts.
    _ = @import("shell.zig");
    _ = @import("scripts.zig");

    // Linux-only (io_uring, unix sockets, SHM).
    if (builtin.target.os.tag == .linux) {
        _ = @import("framework/message_bus.zig");
        _ = @import("framework/io/linux.zig");
        _ = @import("framework/worker_dispatch.zig");
        _ = @import("worker_integration_test.zig");
    }
}
