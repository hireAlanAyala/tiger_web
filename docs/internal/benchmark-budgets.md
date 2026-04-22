# Benchmark budgets — calibration reference

Source of truth for the `assert_budget` thresholds in every
`*_benchmark.zig` file at repo root. Each file header points here;
this doc holds the actual observations.

## Environment (current — dev-machine Debug)

| Property | Value |
|---|---|
| OS | Linux 6.18.13-arch1-1 |
| Mode | `zig build bench` (Debug) |
| Runner class | dev machine (pre-CI) |

Budgets are **placeholders pending Phase F**, which re-runs the same
calibration on `ubuntu-22.04` under `ReleaseSafe` and regenerates this
table. Until then:

- Every budget here is `10× max(3 runs)` rounded up to a readable
  figure, per plan engineering-value-7.
- Debug-mode numbers on a quiescent dev machine are typically 2–5×
  faster than GitHub Actions `ubuntu-22.04` Debug, and 5–10× faster
  than `ReleaseSafe` where AES-NI / SIMD paths engage.
- Budgets are **generous by design** to avoid false positives on slow
  CI runners; they catch only order-of-magnitude regressions.

## Per-bench calibration

### aegis_checksum_benchmark.zig

Kernel: `framework/checksum.zig:checksum` — Aegis-128L MAC.

Smoke mode is 1 KiB; benchmark mode is 1 MiB. `assert_budget` fires
in smoke only, so calibration uses 1 KiB input (forced in benchmark
mode via `blob_size=1024 ./zig/zig build bench` to observe).

| Run | Duration |
|---|---|
| 1 | 4942 ns |
| 2 | 2976 ns |
| 3 | 4841 ns |
| max | 4942 ns |
| 10× | 49420 ns |
| **budget** | **50 000 ns** |

### crc_frame_benchmark.zig

Kernel: `framework/shm_layout.zig:crc_frame` — CRC32 of
`len (u32 LE) ++ payload`. Smoke and benchmark modes see the same
fixed size array, so observed numbers apply to both.

| Size    | Run 1    | Run 2    | Run 3    | max      | 10×       | budget       |
|---------|----------|----------|----------|----------|-----------|--------------|
| 64 B    |   1366   |    615   |    316   |   1366   |   13 660  |     15 000   |
| 256 B   |   4735   |   2103   |   1086   |   4735   |   47 350  |     50 000   |
| 1024 B  |  14722   |   8060   |   4194   |  14722   |  147 220  |    150 000   |
| 4096 B  |  54241   |  32239   |  16417   |  54241   |  542 410  |    600 000   |
| 65536 B | 260480   | 264483   | 119601   | 264483   |2 644 830  |  3 000 000   |

Note: run 1 numbers are consistently highest — cold cache on first
`zig build bench` invocation after a rebuild. Runs 2 and 3 were
warmer. The `max` row uses the actual max across the three.

### hmac_session_benchmark.zig

Kernel: `framework/auth.zig:verify_cookie` — 97-byte cookie: length
check, separator decode, hex decode of user_id and HMAC, HMAC-SHA256
recompute, `timingSafeEql`. Fixed input (no parameter).

| Run | Duration |
|---|---|
| 1 | 2109 ns |
| 2 | 2072 ns |
| 3 | 2691 ns |
| max | 2691 ns |
| 10× | 26 910 ns |
| **budget** | **30 000 ns** |

### wal_parse_benchmark.zig

Kernel: `framework/wal.zig:skip_writes_section` +
`framework/pending_dispatch.zig:parse_one_dispatch` over a hand-built
in-memory body (3 writes + 2 dispatches, ~300 bytes). Fixed input.

| Run | Duration |
|---|---|
| 1 | 139 ns |
| 2 | 136 ns |
| 3 | 112 ns |
| max | 139 ns |
| 10× | 1390 ns |
| **budget** | **2000 ns** |

### route_match_benchmark.zig

Kernel: full iteration over `generated/routes.generated.zig` calling
`framework/parse.zig:match_route` for each row. One sample = one
pass over the 5-probe fixed set × ~24 routes.

| Run | Duration |
|---|---|
| 1 | 4083 ns |
| 2 | 6485 ns |
| 3 | 5702 ns |
| max | 6485 ns |
| 10× | 64 850 ns |
| **budget** | **70 000 ns** |

### state_machine_benchmark.zig (pipeline-tier)

Pre-dates phase C. Original budgets (500 / 2000 / 1000 µs) were
calibrated on a slow CI runner in smoke mode prior to the 3-run
discipline. Phase F will recalibrate these alongside the primitives.

## Regenerating

To refresh these numbers on a new environment (CI runner, new dev
machine, etc.):

```sh
# Run three times. For benches with a parameter, force smoke-equivalent
# input via env var so the numbers apply to smoke mode.
for i in 1 2 3; do ./zig/zig build bench | grep -E "= .* ns"; done
for i in 1 2 3; do blob_size=1024 ./zig/zig build bench | grep "aegis_checksum"; done
```

Then update this doc and the `budget_ns_smoke_max` constants in each
`*_benchmark.zig`. The file headers point here for the observation
tables; only the single budget number lives in the `.zig` file
itself.

## Invariants worth preserving when regenerating

- **3 runs minimum.** Single-run numbers hide cold-cache variance;
  we've seen 4× spread between run 1 and run 3.
- **max, not median.** Budget guards the worst observed case so a
  cold CI run doesn't false-positive.
- **Round up.** `max × 10` is a sketch; round to a readable figure
  (15_000, 50_000, 3_000_000) so the constant is legible at the
  call site.
- **Rerun after any change to the kernel.** A budget is a property
  of the kernel, not the bench file. If `crc_frame` gains a branch,
  recalibrate.
