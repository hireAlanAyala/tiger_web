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
//! **Granularity:** per-passage transplant with file:line citations,
//! not whole-file `cp`-then-trim. Engineering value 2 ("copy-first,
//! trim-second at whatever granularity the TB file permits") picks
//! the granularity from survival ratio: ≥80% → whole-file; below →
//! per-passage. DR-4 put this file at ~25%, so per-passage is the
//! correct scope. Transplanted passages below cite TB line numbers;
//! deletions are grouped by concern with bucket tags.
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
//! **Transplanted (TB lines verbatim, with path / unit swaps):**
//!
//!   - `build_time_debug_ms` + `build_time_ms` + `executable_size_bytes`
//!     (TB lines 109–127). Debug build → release build (cache
//!     cleaned between), each wrapped in a `std.time.Timer`. Release
//!     build's output is stat'd for size. Our binary is
//!     `zig-out/bin/tiger-web`; TB's is the top-level `tigerbeetle`.
//!   - `replica log lines` analog — `bench_log_lines`, counted from
//!     the SLA benchmark's stderr (TB lines 174 / 193 / 350).
//!   - `upload_nyrkio` (TB lines 454–466). POSTs each `MetricBatch`
//!     to Nyrkiö's change-point detection service alongside the
//!     devhubdb git-push. One principled divergence: `env_get` →
//!     `env_get_option` so a missing `NYRKIO_TOKEN` is a graceful
//!     no-op rather than an error routed through the outer catch.
//!     Semantically identical to TB's end-to-end behavior, but the
//!     intent (optional destination) is explicit at the call site.
//!   - `devhub_coverage` (TB lines 58–95). kcov orchestration:
//!     build → run tests under ptrace → write HTML report →
//!     symlink-cleanup for Pages upload. Principled divergences:
//!     binary names (tiger-*), flat source layout (no `src/`),
//!     fuzzer set (five tiger-web fuzzers replacing TB's
//!     lsm_tree/lsm_forest/vopr), events-max 100k vs 500k. Full
//!     per-line citations on the function's docblock.
//!
//! **Deletions (all principled — tigerbeetle-binary-specific or
//! scoped to a later phase):**
//!
//!   - Changelog detection + `no_changelog_flag` branching
//!     (TB lines 129–164) — TB-release-specific.
//!   - `./tigerbeetle benchmark` stdout parsing for TB-specific
//!     metrics (TB lines 174–204): `tx/s`, `batch p100`, `query p100`,
//!     `rss`, `datafile`, `checksum(message_size_max)`. None apply
//!     to our benches.
//!   - `tigerbeetle inspect integrity` / `format` / `start` + manual
//!     `Header.PingClient` TCP ping (TB lines 180–309) — tigerbeetle-
//!     CLI-specific.
//!   - `ci_pipeline_duration_s` query (TB lines 311–332).
//!     **Revisit after `workflow_run` split** — TB uses `merge_group`
//!     (a completed prior workflow); our `push` trigger runs devhub
//!     inside the workflow it would measure, so `updatedAt -
//!     startedAt` is a partial duration that doesn't match the
//!     metric's name. See `devhub_metrics` body for full context.
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
    /// Tiger-web addition, not in TB. **Principled divergence:** our
    /// CI invokes this script on PR builds too (for end-to-end dry
    /// verification — see `.github/workflows/ci.yml` "devhub" job,
    /// which branches on `github.event_name`); TB's pipeline only
    /// invokes devhub on merged commits. The `--dry-run` branch
    /// prints the `MetricBatch` JSON to stdout instead of cloning
    /// devhubdb + pushing.
    dry_run: bool = false,
    /// Verbatim from TB `CLIArgs` (TB:45). Gates the expensive kcov
    /// pass so local invocations can skip it; CI leaves the default
    /// (runs coverage). Name + default + semantics all match TB.
    skip_kcov: bool = false,
};

pub fn main(shell: *Shell, _: std.mem.Allocator, cli_args: CLIArgs) !void {
    try devhub_metrics(shell, cli_args);

    // TB lines 51–55 verbatim: coverage follows the metrics pass;
    // `--skip-kcov` short-circuits it for local runs.
    if (!cli_args.skip_kcov) {
        try devhub_coverage(shell);
    } else {
        log.info("--skip-kcov enabled, not computing coverage.", .{});
    }
}

fn devhub_metrics(shell: *Shell, cli_args: CLIArgs) !void {
    var section = try shell.open_section("metrics");
    defer section.close();

    // Commit timestamp. Preserves TB's `git show -s --format=%ct` +
    // parseInt shape (TB lines 101–103).
    const commit_timestamp_str =
        try shell.exec_stdout("git show -s --format=%ct {sha}", .{ .sha = cli_args.sha });
    const commit_timestamp = try std.fmt.parseInt(u64, commit_timestamp_str, 10);

    // --- Build-time and binary-size metrics ---
    //
    // Transplanted from TB lines 107–127. Debug build first, then a
    // cache-cleared release build. Release build's binary is stat'd
    // for size. The SLA-tier benchmark later re-uses the release
    // install, so no wasted build work.
    //
    // Principled divergence from TB: TB wraps each build in a
    // `defer shell.project_root.deleteFile("tigerbeetle")` to avoid
    // stale-binary state between builds. We skip the delete — Zig's
    // `addInstallArtifact` step overwrites `zig-out/bin/tiger-web`
    // atomically on each `build install`, so there's no stale-state
    // risk. Also keeps the release binary on disk for the SLA bench
    // below (TB deletes theirs and unzips from `zig-out/dist/`).
    var timer = try std.time.Timer.start();

    const build_time_debug_ms = blk: {
        timer.reset();
        try shell.exec_zig("build install", .{});
        break :blk timer.read() / std.time.ns_per_ms;
    };

    const build_time_ms, const executable_size_bytes = blk: {
        timer.reset();
        try shell.project_root.deleteTree(".zig-cache");
        try shell.exec_zig("build -Doptimize=ReleaseSafe install", .{});
        break :blk .{
            timer.read() / std.time.ns_per_ms,
            (try shell.cwd.statFile("zig-out/bin/tiger-web")).size,
        };
    };

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
    // parse its output, kill the server. The release install above
    // already produced `zig-out/bin/tiger-web`, so no re-build here.
    // Separate function so the server's teardown is guaranteed via
    // defer even on parse error.
    const sla = try run_sla_benchmark(shell);

    // `ci_pipeline_duration_s` deliberately not emitted here — see
    // file header "Deletions" entry for full context. Short version:
    // our `push` trigger runs devhub inside the workflow it would
    // measure, so `gh run list`'s `updatedAt - startedAt` is a
    // partial duration that doesn't match the metric's name.
    // Revisit after `workflow_run` split (tracked follow-up).

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
            //
            // `benchmark_load` also emits `closed_loop = 1 count`
            // as stdout metadata. Not forwarded here: it's a
            // constant-1 signal (we're always closed-loop until the
            // open-loop follow-up lands), so it has no time-series
            // value for the dashboard. Documented so a reader
            // grepping the bench output against the dashboard's
            // metric list finds the principle (don't forward
            // constant-valued signals).
            .{ .name = "benchmark_throughput", .value = sla.throughput, .unit = "req/s" },
            .{ .name = "benchmark_latency_p1", .value = sla.p1, .unit = "ms" },
            .{ .name = "benchmark_latency_p50", .value = sla.p50, .unit = "ms" },
            .{ .name = "benchmark_latency_p99", .value = sla.p99, .unit = "ms" },
            .{ .name = "benchmark_latency_p100", .value = sla.p100, .unit = "ms" },
            .{ .name = "benchmark_errors", .value = sla.errors, .unit = "count" },
            // Build signals + log-volume. Audit 2026-04-23 retrofit
            // (H.2). TB emits these; we dropped them at E ship time
            // and re-added under the "don't omit what TB has" bias.
            // `ci_pipeline_duration_s` intentionally omitted — see
            // the note in `devhub_metrics` above.
            //
            // `bench_log_lines` baseline is tight: the current
            // `benchmark_load` emits exactly two lines (`log.info`
            // at startup + `log.warn` trailer about closed-loop
            // omission). A flat line at 2 on the dashboard is the
            // "no regression" state — any bump means a hot-path
            // logging call landed.
            .{ .name = "executable_size_bytes", .value = executable_size_bytes, .unit = "bytes" },
            .{ .name = "build_time_ms", .value = build_time_ms, .unit = "ms" },
            .{ .name = "build_time_debug_ms", .value = build_time_debug_ms, .unit = "ms" },
            .{ .name = "bench_log_lines", .value = sla.log_lines, .unit = "count" },
        },
    };

    if (cli_args.dry_run) {
        log.info("dry-run: MetricBatch follows (not uploaded)", .{});
        const payload = try std.json.stringifyAlloc(shell.arena.allocator(), batch, .{ .whitespace = .indent_2 });
        shell.echo("{s}", .{payload});
    } else {
        // TB lines 366–372 — two *independent* upload destinations.
        // Failure of one doesn't block the other: both catches log
        // and continue. devhubdb holds the raw time series; Nyrkiö
        // does change-point detection on the same batches. A
        // transient push failure to devhubdb shouldn't forfeit the
        // Nyrkiö datapoint for that commit.
        //
        // Surgical addition on top of TB's shape: we track which
        // destination actually succeeded so we can fail the CI job
        // if both silently no-op'd. TB doesn't need this because
        // they treat devhubdb + Nyrkiö as independent-but-parallel
        // destinations and accept rare simultaneous failures. Our
        // Nyrkiö token isn't set yet, so "Nyrkiö ok" under our
        // current state means "skipped because unconfigured" — not
        // a real data point. Without this check, a transient
        // devhubdb failure would silently drop a commit's row from
        // the dashboard, green CI included.
        const devhubdb_uploaded = if (upload_run(shell, &batch)) |_| true else |err| blk: {
            log.err("failed to upload devhubdb metrics: {}", .{err});
            break :blk false;
        };
        const nyrkio_uploaded = upload_nyrkio(shell, &batch) catch |err| blk: {
            log.err("failed to upload Nyrkiö metrics: {}", .{err});
            break :blk false;
        };
        if (!devhubdb_uploaded and !nyrkio_uploaded) {
            log.err(
                "all upload destinations failed or unconfigured — " ++
                    "dashboard will miss this commit",
                .{},
            );
            return error.AllUploadsFailed;
        }
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
    /// Count of newlines in the benchmark's stderr. Analog of TB's
    /// `replica log lines` (TB `devhub.zig:193`). Silent spikes here
    /// flag hot-path logging regressions — e.g., someone adds a
    /// `log.debug` inside the send loop and doesn't notice until the
    /// dashboard's log-line metric steps up. H.2 retrofit.
    log_lines: u64,
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

    // Capture both streams: stdout carries the parsed metric lines,
    // stderr carries log output. The stderr newline count is our
    // `bench_log_lines` metric (analog of TB's `replica log lines`).
    const bench_captured = shell.exec_stdout_stderr(
        "zig-out/bin/tiger-web benchmark --port={port} --connections=64 --requests=50000",
        .{ .port = port },
    ) catch |err| {
        log.err("SLA benchmark: `tiger-web benchmark` failed: {s}", .{@errorName(err)});
        return error.SlaBenchmarkFailed;
    };
    const bench_stdout = bench_captured[0];
    const bench_stderr = bench_captured[1];
    const log_lines: u64 = @intCast(std.mem.count(u8, bench_stderr, "\n"));

    return .{
        .throughput = try get_measurement(bench_stdout, "benchmark_throughput", "req/s"),
        .p1 = try get_measurement(bench_stdout, "benchmark_latency_p1", "ms"),
        .p50 = try get_measurement(bench_stdout, "benchmark_latency_p50", "ms"),
        .p99 = try get_measurement(bench_stdout, "benchmark_latency_p99", "ms"),
        .p100 = try get_measurement(bench_stdout, "benchmark_latency_p100", "ms"),
        .errors = try get_measurement(bench_stdout, "benchmark_errors", "count"),
        .log_lines = log_lines,
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

/// Near-verbatim from TB lines 454–466. Two principled divergences:
///
/// 1. `env_get` → `env_get_option` so a missing `NYRKIO_TOKEN` returns
///    null (graceful skip) rather than propagating an error. TB's
///    call site catches and logs without aborting; end-to-end
///    behavior matches, but the intent (optional destination) is
///    visible at the call.
///
/// 2. Return type `!void` → `!bool` where `true = actually uploaded,
///    `false = skipped because unconfigured`. Enables the caller to
///    distinguish "Nyrkiö is off by design" from "Nyrkiö uploaded a
///    real datapoint" — load-bearing for the at-least-one-destination
///    check at the call site (returns `error.AllUploadsFailed`, not
///    a TIGER_STYLE `assert()`-style panic — CI needs a loud
///    non-zero exit, not a crashed process). TB doesn't need this
///    distinction
///    because their Nyrkiö is always configured; our secret isn't
///    set yet, so the no-op state is the current default.
///
/// Nyrkiö is a hosted change-point detection service: POSTing
/// `MetricBatch` arrays on every commit lets it flag the exact SHA
/// where a metric's distribution shifts. Until we register an
/// account and set `NYRKIO_TOKEN` in CI, this function is a no-op.
///
/// **No unit test.** TB doesn't unit-test `upload_nyrkio`; the skip
/// path (3 lines of trivial logic) is exercised on the first main
/// merge with `NYRKIO_TOKEN` unset, which is the current state. A
/// unit test would require either process-env manipulation (fragile)
/// or refactoring to accept the token as a parameter (TB divergence).
fn upload_nyrkio(shell: *Shell, batch: *const MetricBatch) !bool {
    const token = shell.env_get_option("NYRKIO_TOKEN") orelse {
        // log.debug not log.info: this fires on every build until
        // the secret lands. Surfacing it once in a reviewer's terminal
        // is useful, but per-run `info` output is noise until the
        // change-point destination is wired up.
        log.debug("NYRKIO_TOKEN not set; skipping Nyrkiö upload", .{});
        return false;
    };
    const url = "https://nyrkio.com/api/v0/result/devhub";
    const payload = try std.json.stringifyAlloc(
        shell.arena.allocator(),
        [_]*const MetricBatch{batch}, // Nyrkiö needs an _array_ of batches.
        .{},
    );
    _ = try shell.http_post(url, payload, .{
        .content_type = .json,
        .authorization = try shell.fmt("Bearer {s}", .{token}),
    });
    log.info("Nyrkiö metrics uploaded", .{});
    return true;
}

/// Near-verbatim from TB lines 58–95. Surgical edits bucket-tagged
/// inline. The kcov invocation shape, symlink-cleanup, seed `92`,
/// and `exec_stdout("kcov --version")` probe are preserved verbatim.
///
/// Divergences, all principled (our repo differs from TB's in layout
/// and binary names):
///
///   - `zig-out/bin/test-unit` → `zig-out/bin/tiger-unit-test` (our
///     binary, produced by Phase G.0.a's `unit-test-build` step).
///   - `zig-out/bin/fuzz` → `zig-out/bin/tiger-fuzz` (our binary,
///     produced by `zig build install`).
///   - TB's `build vopr:build` + VOPR invocation dropped — no VOPR
///     analog in tiger-web. Its coverage contribution is replaced
///     by our full fuzzer set (5 fuzzers) below.
///   - TB's `build fuzz:build` step → `build install` — our
///     `tiger-fuzz` is a regular executable, not a separate
///     test-artifact install.
///   - TB's LSM fuzz invocations (`lsm_tree`, `lsm_forest`) dropped
///     — no LSM subsystem. Replaced with our 5 fuzzers (rationale
///     in the benchmark-tracking plan's G.0.b discussion:
///     cross-language + concurrent + durable-format boundaries).
///   - `events-max=500000` → `events-max=100000`. Middle ground
///     between smoke-mode (10k) and TB's LSM-sized run (500k);
///     keeps coverage CI bounded at ~1–2 min per fuzzer. Revisit
///     if coverage % stays flat after more events.
///   - `--include-path=./src` → `--include-path=./`. Our source is
///     flat from repo root (no `src/` subdirectory). kcov reports
///     on everything in the tree including tests and vendored
///     code; acceptable — the alternative of listing every source
///     dir (`./framework`, `./scripts`, `./packages`, etc.) would
///     silently drop coverage for new directories.
///   - `./src/devhub/coverage` → `./coverage`. Output lives at the
///     repo root; CI uploads it to Pages via
///     `actions/upload-pages-artifact` alongside `devhub/data.json`
///     (see `.github/workflows/ci.yml`).
fn devhub_coverage(shell: *Shell) !void {
    var section = try shell.open_section("coverage");
    defer section.close();

    const kcov_version = shell.exec_stdout("kcov --version", .{}) catch {
        return error.NoKcov;
    };
    log.info("kcov version {s}", .{kcov_version});

    try shell.exec_zig("build unit-test-build", .{});
    // `-Doptimize=ReleaseSafe` matches the release build from
    // `devhub_metrics` above — without it, the default (debug)
    // optimize mode rebuilds tiger-web + tiger-fuzz from scratch
    // (~48s wasted) AND overwrites the release tiger-web that the
    // SLA benchmark already exercised, leaving a debug binary as
    // the final state. Passing release here cache-hits on
    // tiger-web and just builds tiger-fuzz at release mode too.
    try shell.exec_zig("build -Doptimize=ReleaseSafe install", .{}); // produces tiger-fuzz

    // Clean output dir — kcov aggregates across runs if we don't.
    try shell.project_root.deleteTree("./coverage");
    try shell.project_root.makePath("./coverage");

    const kcov: []const []const u8 = &.{ "kcov", "--include-path=./", "./coverage" };
    // KEEP IN SYNC with `fuzz_tests.zig:Fuzzers`. Adding a 6th
    // real fuzzer there requires a matching entry here; otherwise
    // its coverage contribution is silently absent from the report.
    // The mirror comment at `Fuzzers` points back here.
    // tiger-stdx-test's flags-test fixture reads ZIG_EXE (matches
    // TB's stdx test, which TB wires via `setEnvironmentVariable`
    // on the test run-artifact). Subprocesses inherit our env, so
    // ZIG_EXE flows through to kcov → tiger-stdx-test as long as
    // it's set in our env. Assert presence here with a clear
    // error rather than letting one stdx test fail cryptically
    // with EnvironmentVariableNotFound mid-coverage-run.
    _ = shell.env_get("ZIG_EXE") catch {
        log.err("ZIG_EXE not set; tiger-stdx-test will fail. " ++
            "Run via `zig build scripts -- devhub` so ZIG_EXE " ++
            "is propagated.", .{});
        return error.MissingZigExe;
    };

    inline for (.{
        "{kcov} ./zig-out/bin/tiger-unit-test",
        "{kcov} ./zig-out/bin/tiger-stdx-test",
        "{kcov} ./zig-out/bin/tiger-fuzz --events-max=100000 state_machine 92",
        "{kcov} ./zig-out/bin/tiger-fuzz --events-max=100000 replay 92",
        "{kcov} ./zig-out/bin/tiger-fuzz --events-max=100000 message_bus 92",
        "{kcov} ./zig-out/bin/tiger-fuzz --events-max=100000 row_format 92",
        "{kcov} ./zig-out/bin/tiger-fuzz --events-max=100000 worker_dispatch 92",
    }) |command| {
        try shell.exec(command, .{ .kcov = kcov });
    }

    var coverage_dir = try shell.cwd.openDir("./coverage", .{ .iterate = true });
    defer coverage_dir.close();

    // kcov adds some symlinks to the output, which prevents upload to
    // GitHub actions from working. Verbatim from TB:88-93.
    var it = coverage_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) {
            try coverage_dir.deleteFile(entry.name);
        }
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
