//! Devhub metrics uploader.
//!
//! Runs the benchmark pipeline on every merge to `main`, serializes
//! the results as a `MetricBatch` JSON object, and appends the entry
//! to `hireAlanAyala/tiger-web-devhubdb/devhub/data.json` via
//! git-clone-reset-append-commit-push. The dashboard (Phase G) reads
//! the same file.
//!
//! **Port source:** `src/scripts/devhub.zig` from TigerBeetle
//! (`/home/walker/Documents/personal/tigerbeetle`, 466 lines).
//! Survival ~25% (per DR-4). The transplantable structures live here;
//! tigerbeetle-binary-specific orchestration was dropped.
//!
//! **Transplanted verbatim from template:**
//!
//!   - `Metric` struct — TB lines 438–442.
//!   - `MetricBatch` struct — TB lines 444–452.
//!   - `get_measurement` helper — TB lines 379–393. Parses
//!     `"label = value unit"` lines; DR-2 confirmed our bench output
//!     matches this shape verbatim.
//!   - `upload_run` git-clone/fetch/reset/append/commit/push loop
//!     with 32-retry on conflict — TB lines 395–436.
//!
//! **Deletions (all principled — tigerbeetle-binary-specific):**
//!
//!   - `devhub_coverage` + kcov orchestration (TB lines 58–95) — we
//!     don't ship a kcov-based coverage artifact.
//!   - `build_time_debug_ms` / `build_time_ms` / `executable_size_bytes`
//!     (TB lines 109–127) — TB tracks release-build size and time;
//!     tiger-web doesn't ship a single binary we release against.
//!     If we ever do, revisit.
//!   - Changelog detection + `no_changelog_flag` branching
//!     (TB lines 129–164) — TB-release-specific.
//!   - `./tigerbeetle benchmark` stdout parsing for TB-specific
//!     metrics (TB lines 174–204): `tx/s`, `batch p100`, `query p100`,
//!     `rss`, `datafile`, `checksum(message_size_max)`. None of these
//!     apply to our benches.
//!   - `tigerbeetle inspect integrity` / `format` / `start` + manual
//!     `Header.PingClient` TCP ping (TB lines 180–309) — tigerbeetle-
//!     CLI-specific; we have no equivalent binary commands.
//!   - `gh run list` CI-pipeline-duration query (TB lines 311–332) —
//!     tracked as follow-up: we could add this to measure our own CI
//!     pipeline duration once phase F has been running long enough to
//!     have representative data.
//!   - `upload_nyrkio` (TB lines 454–466) — TB double-publishes to
//!     Nyrkiö; we're single-target (devhubdb only).
//!
//! **Surgical edits on transplanted structures:**
//!
//!   - `upload_run` clone URL:
//!     `github.com/tigerbeetle/devhubdb` →
//!     `github.com/hireAlanAyala/tiger-web-devhubdb`.
//!   - `MetricBatch.attributes.git_repo` value:
//!     `https://github.com/tigerbeetle/tigerbeetle` →
//!     `https://github.com/hireAlanAyala/tiger_web`.
//!
//! **Written fresh for Tiger Web (no TB equivalent applies):**
//!
//!   - `devhub_metrics` body — runs `./zig/zig build bench`, captures
//!     stderr (where `bench.report` writes via `std.debug.print`),
//!     parses per-bench metrics via `get_measurement`, builds
//!     `MetricBatch`.
//!   - `CLIArgs` — `sha: []const u8` + `dry_run: bool = false`.
//!     We don't carry `skip_kcov` (no kcov).
//!
//! **Execution order note (plan 2026-04-22 revision):** at this
//! file's ship time, `MetricBatch.metrics` carries only primitive +
//! pipeline tiers (no SLA yet). Phase D adds the SLA tier by
//! inserting a `./zig-out/bin/tiger-web benchmark` call into
//! `devhub_metrics` and appending its parsed metrics.
//!
//! **Upload semantics:** append-only, not merge. One entry per
//! `(commit_sha, timestamp)`; no deduplication, no aggregation. 32
//! push-conflict retries; fail hard if exhausted.
//!
//! Full PAT / secret setup is documented in the plan's
//! "Blocking on human" section.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;

const stdx = @import("stdx");
const Shell = @import("../shell.zig");

const log = std.log;

pub const CLIArgs = struct {
    sha: []const u8,
    dry_run: bool = false,
};

pub fn main(shell: *Shell, _: std.mem.Allocator, cli_args: CLIArgs) !void {
    try devhub_metrics(shell, cli_args);
}

fn devhub_metrics(shell: *Shell, cli_args: CLIArgs) !void {
    var section = try shell.open_section("metrics");
    defer section.close();

    // Commit timestamp. Preserves TB's `git show -s --format=%ct` +
    // parseInt shape (TB lines 101–103).
    const commit_timestamp_str =
        try shell.exec_stdout("git show -s --format=%ct {sha}", .{ .sha = cli_args.sha });
    const commit_timestamp = try std.fmt.parseInt(u64, commit_timestamp_str, 10);

    // Run the bench pipeline end-to-end once. `bench.report` writes
    // to stderr via `std.debug.print`, so the measurement lines are
    // in the stderr capture.
    const bench_captured = try shell.exec_stdout_stderr("./zig/zig build bench", .{});
    const bench_output = bench_captured[1];

    const aegis_checksum_ns = try get_measurement(bench_output, "aegis_checksum", "ns");
    const crc_frame_64_ns = try get_measurement(bench_output, "crc_frame_64", "ns");
    const crc_frame_256_ns = try get_measurement(bench_output, "crc_frame_256", "ns");
    const crc_frame_1024_ns = try get_measurement(bench_output, "crc_frame_1024", "ns");
    const crc_frame_4096_ns = try get_measurement(bench_output, "crc_frame_4096", "ns");
    const crc_frame_65536_ns = try get_measurement(bench_output, "crc_frame_65536", "ns");
    const hmac_session_ns = try get_measurement(bench_output, "hmac_session", "ns");
    const wal_parse_ns = try get_measurement(bench_output, "wal_parse", "ns");
    const route_match_ns = try get_measurement(bench_output, "route_match", "ns");
    const get_product_ns = try get_measurement(bench_output, "get_product", "ns");
    const list_products_ns = try get_measurement(bench_output, "list_products", "ns");
    const update_product_ns = try get_measurement(bench_output, "update_product", "ns");

    // SLA tier: start an ephemeral server, run `tiger-web benchmark`,
    // parse its output, kill the server. Release build so the
    // numbers reflect production shape. Separate function so the
    // server's teardown is guaranteed via defer even on parse error.
    try shell.exec_zig("build -Doptimize=ReleaseSafe", .{});
    const sla = try run_sla_benchmark(shell);

    const batch = MetricBatch{
        .timestamp = commit_timestamp,
        .attributes = .{
            .git_repo = "https://github.com/hireAlanAyala/tiger_web",
            .git_commit = cli_args.sha,
            .branch = "main",
        },
        .metrics = &[_]Metric{
            // Primitive tier — one per kernel.
            .{ .name = "aegis_checksum", .value = aegis_checksum_ns, .unit = "ns" },
            .{ .name = "crc_frame_64", .value = crc_frame_64_ns, .unit = "ns" },
            .{ .name = "crc_frame_256", .value = crc_frame_256_ns, .unit = "ns" },
            .{ .name = "crc_frame_1024", .value = crc_frame_1024_ns, .unit = "ns" },
            .{ .name = "crc_frame_4096", .value = crc_frame_4096_ns, .unit = "ns" },
            .{ .name = "crc_frame_65536", .value = crc_frame_65536_ns, .unit = "ns" },
            .{ .name = "hmac_session", .value = hmac_session_ns, .unit = "ns" },
            .{ .name = "wal_parse", .value = wal_parse_ns, .unit = "ns" },
            .{ .name = "route_match", .value = route_match_ns, .unit = "ns" },
            // Pipeline tier — state machine prefetch + commit.
            .{ .name = "get_product", .value = get_product_ns, .unit = "ns" },
            .{ .name = "list_products", .value = list_products_ns, .unit = "ns" },
            .{ .name = "update_product", .value = update_product_ns, .unit = "ns" },
            // SLA tier — closed-loop HTTP throughput + percentiles.
            .{ .name = "benchmark_throughput", .value = sla.throughput, .unit = "req/s" },
            .{ .name = "benchmark_latency_p1", .value = sla.p1, .unit = "ms" },
            .{ .name = "benchmark_latency_p50", .value = sla.p50, .unit = "ms" },
            .{ .name = "benchmark_latency_p99", .value = sla.p99, .unit = "ms" },
            .{ .name = "benchmark_latency_p100", .value = sla.p100, .unit = "ms" },
            .{ .name = "benchmark_errors", .value = sla.errors, .unit = "count" },
        },
    };

    if (cli_args.dry_run) {
        log.info("dry-run: MetricBatch follows (not uploaded)", .{});
        const payload = try std.json.stringifyAlloc(shell.arena.allocator(), batch, .{ .whitespace = .indent_2 });
        shell.echo("{s}", .{payload});
    } else {
        upload_run(shell, &batch) catch |err| {
            log.err("failed to upload devhubdb metrics: {}", .{err});
            return err;
        };
    }

    for (batch.metrics) |metric| {
        std.log.info("{s} = {} {s}", .{ metric.name, metric.value, metric.unit });
    }
}

// --- SLA benchmark orchestration ---
//
// Written fresh (no TB equivalent — TB spawns `tigerbeetle` + runs
// `tigerbeetle benchmark`; ours spawns `tiger-web start` + runs
// `tiger-web benchmark`). Shape borrows from the removed
// `scripts/perf.zig` orchestration at commit `67993e8~1`: start
// with --port=0, read actual port from stdout, run tool against
// it, SIGTERM on teardown.
//
// Errors during the run return error.SlaBenchmarkFailed rather
// than partial data; devhub would rather fail loud than upload a
// bad SLA row.

const SlaMetrics = struct {
    throughput: u64,
    p1: u64,
    p50: u64,
    p99: u64,
    p100: u64,
    errors: u64,
};

const sla_db_path = "tiger_web_devhub_sla.db";

fn run_sla_benchmark(shell: *Shell) !SlaMetrics {
    log.info("SLA benchmark: starting ephemeral server...", .{});
    var server = try shell.spawn(
        .{
            .stdin_behavior = .Pipe,
            .stdout_behavior = .Pipe,
            .stderr_behavior = .Inherit,
        },
        "zig-out/bin/tiger-web start --port=0 --db={db}",
        .{ .db = sla_db_path },
    );
    defer {
        if (server.stdin) |stdin| {
            stdin.close();
            server.stdin = null;
        }
        _ = posix.kill(server.id, posix.SIG.TERM) catch {};
        _ = server.wait() catch {};
        // Clean up the database files regardless of success.
        for ([_][]const u8{ sla_db_path, sla_db_path ++ "-wal", sla_db_path ++ "-shm", "tiger_web.wal" }) |path| {
            shell.cwd.deleteFile(path) catch {};
        }
    }

    // Read port from server's readiness signal (stdout line).
    var port_buf: [6]u8 = undefined;
    const port_n = server.stdout.?.read(&port_buf) catch |err| {
        log.err("SLA benchmark: failed to read port from server: {s}", .{@errorName(err)});
        return error.SlaBenchmarkFailed;
    };
    if (port_n == 0) {
        log.err("SLA benchmark: server exited before writing port", .{});
        return error.SlaBenchmarkFailed;
    }
    const port_end = if (port_n > 0 and port_buf[port_n - 1] == '\n') port_n - 1 else port_n;
    const port = port_buf[0..port_end];

    log.info("SLA benchmark: server on port {s}, running load...", .{port});

    const bench_out = shell.exec_stdout(
        "zig-out/bin/tiger-web benchmark --port={port} --connections=64 --requests=50000 --warmup-seconds=3",
        .{ .port = port },
    ) catch |err| {
        log.err("SLA benchmark: `tiger-web benchmark` failed: {s}", .{@errorName(err)});
        return error.SlaBenchmarkFailed;
    };

    return .{
        .throughput = try get_measurement(bench_out, "benchmark_throughput", "req/s"),
        .p1 = try get_measurement(bench_out, "benchmark_latency_p1", "ms"),
        .p50 = try get_measurement(bench_out, "benchmark_latency_p50", "ms"),
        .p99 = try get_measurement(bench_out, "benchmark_latency_p99", "ms"),
        .p100 = try get_measurement(bench_out, "benchmark_latency_p100", "ms"),
        .errors = try get_measurement(bench_out, "benchmark_errors", "count"),
    };
}

// =============================================================
// Transplanted from TB (verbatim + URL swap) — `src/scripts/devhub.zig`
// =============================================================

/// Verbatim from TB lines 379–393 — parses `"<label> = <value> <unit>"`
/// out of bench stdout/stderr. DR-2 confirmed our bench output
/// matches this exact shape.
fn get_measurement(
    benchmark_stdout: []const u8,
    comptime label: []const u8,
    comptime unit: []const u8,
) !u64 {
    errdefer {
        std.log.err("can't extract '" ++ label ++ "' measurement", .{});
    }

    _, const rest = stdx.cut(benchmark_stdout, label ++ " = ") orelse
        return error.BadMeasurement;
    const value_string, _ = stdx.cut(rest, " " ++ unit) orelse return error.BadMeasurement;

    return try std.fmt.parseInt(u64, value_string, 10);
}

/// Verbatim from TB lines 395–436 — clone, fetch, reset, append,
/// commit, push with 32-retry on conflict. One surgical edit: clone
/// URL swapped for our devhubdb repo.
fn upload_run(shell: *Shell, batch: *const MetricBatch) !void {
    const token = try shell.env_get("DEVHUBDB_PAT");
    try shell.exec(
        \\git clone --single-branch --depth 1
        \\  https://oauth2:{token}@github.com/hireAlanAyala/tiger-web-devhubdb.git
        \\  devhubdb
    , .{
        .token = token,
    });

    try shell.pushd("./devhubdb");
    defer shell.popd();

    for (0..32) |_| {
        try shell.exec("git fetch origin main", .{});
        try shell.exec("git reset --hard origin/main", .{});

        {
            const file = try shell.cwd.openFile("./devhub/data.json", .{
                .mode = .write_only,
            });
            defer file.close();

            try file.seekFromEnd(0);
            try std.json.stringify(batch, .{}, file.writer());
            try file.writeAll("\n");
        }

        try shell.exec("git add ./devhub/data.json", .{});
        try shell.git_env_setup(.{ .use_hostname = false });
        try shell.exec("git commit -m 📈", .{});
        if (shell.exec("git push", .{})) {
            log.info("metrics uploaded", .{});
            break;
        } else |_| {
            log.info("conflict, retrying", .{});
        }
    } else {
        log.err("can't push new data to devhub", .{});
        return error.CanNotPush;
    }
}

/// Verbatim from TB lines 438–452.
const Metric = struct {
    name: []const u8,
    unit: []const u8,
    value: u64,
};

const MetricBatch = struct {
    timestamp: u64,
    metrics: []const Metric,
    attributes: struct {
        git_repo: []const u8,
        branch: []const u8,
        git_commit: []const u8,
    },
};
