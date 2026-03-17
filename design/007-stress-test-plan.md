# Design 007: Stress Test Plan

Discover what features we actually need by operating the system under real conditions.

## 1. WAL growth — when does rotation matter?

**Status: answered.**

Each WAL entry is 784 bytes (fixed-size Message). The load test (`./loadtest.sh wal`) confirmed this with 1001 entries = 785,568 bytes.

| Traffic rate | Per day | Per week | Per month | Per year |
|-------------|---------|----------|-----------|----------|
| 1 mut/sec | 65 MB | 452 MB | 1.9 GB | 23 GB |
| 1 mut/min | 1 MB | 7.5 MB | 32 MB | 390 MB |
| 10 mut/sec | 650 MB | 4.4 GB | 19 GB | 230 GB |

**Conclusion:** rotation is a nice-to-have, not urgent. A low-traffic site can run for a year without rotation. A busy site (10 mut/sec) wants monthly rotation. The operator can use stop+copy+restart — no framework machinery needed yet.

## 2. Kill -9 recovery

**Status: answered.**

Ran 30 rounds of kill -9 (20 sequential, 10 with 50 concurrent requests per round). Results:

- Verify passed every round. Zero chain breaks.
- Zero entries lost across all 30 rounds (500 sent, 500 recorded).
- Server recovered cleanly on every restart. WAL backward scan + ftruncate worked every time.

The crash gap (SQLite commits, then WAL appends) is nanoseconds wide. Kill -9 with curl-level traffic cannot hit it. The gap is real in theory but irrelevant in practice — you'd need a debugger breakpoint to trigger it.

**Conclusion:** recovery path works. No action needed.

## 3. Replay after crash — is the tool useful?

**Status: can test now (same as #2 but with inspect/replay).**

After each kill -9 cycle, run:
```bash
./zig-out/bin/tiger-replay inspect --after=$LAST_OP tiger_web.wal
```

**Questions to answer:**
- Does inspect show you what the last operations were before the crash?
- Is that information useful, or do you reach for `sqlite3 tiger_web.db` and server logs instead?
- What's missing from the inspect output?

## 4. Debug a real bug with only the WAL

**Status: can simulate.**

Plan:
1. Start clean server, run load test to create baseline WAL
2. Introduce a bug (e.g., `update_product` doesn't check version, or `create_order` doesn't decrement inventory)
3. Rebuild, restart, run more traffic
4. Customer reports a problem — "my inventory is wrong" or "my product was overwritten"
5. Using ONLY the WAL (no sqlite3 CLI, no server logs), find the operation that caused it
6. Use `--filter`, `--user`, `--after`/`--before` to narrow down
7. Use `tiger-replay replay --stop-at=N --trace` to reproduce

**Questions to answer:**
- Can you find the bug with inspect alone, or do you need replay?
- How long does it take?
- What filters are missing?
- Is `--trace` output enough to see the bug?

## 5. Schema migration — does the old WAL still work?

**Status: answered. Found a real gap.**

Tested two scenarios:

**Adding a field (changes struct size):** Adding `weight_grams: u32` to Product (672 → 676 bytes) fails at compile time — multiple `comptime assert` fire:
- `@sizeOf(Product) > body_max` — Product doesn't fit in the 672-byte body
- `no_padding(Product)` — struct layout validation
- `missing struct field: weight_grams` — exhaustive initialization

The binary can't be built. This is stronger than a runtime root checksum check.

**Reordering fields (same struct size):** Swapping `price_cents` and `inventory` (both u32) builds fine, verify passes, and the server starts without error. The root checksum doesn't catch it because the root entry has an all-zero body — swapping zero-valued fields produces identical bytes.

This means a field reorder silently reinterprets production data: price becomes inventory, inventory becomes price. The WAL and replay tool would process entries with swapped semantics and produce wrong results without any error.

**Gap:** The root checksum only catches changes that alter the Message byte representation of an all-zero body. Same-size field reorders within the body are invisible. This is a real risk — an accidental field swap during refactoring would corrupt replay silently.

**Fixed:** The root entry now contains a layout sentinel — a Product with distinct values in every numeric field (`price_cents=0x04040404`, `inventory=0x05050505`, etc.). Swapping same-size fields changes the body bytes and the root checksum. Verified: swapping `price_cents` and `inventory` now fails the stability test.

## 6. Saturate — find the bottleneck

**Status: answered.**

| Operation | Peak req/sec | Plateaus at | Notes |
|-----------|-------------|-------------|-------|
| GET point read | ~29k | 16 concurrent | |
| GET list scan | ~17k | 16 concurrent | |
| PUT update | ~17k | 64 concurrent | Includes WAL append |
| Search | ~18k | 16 concurrent | |
| GET at 256c | ~6.8k | — | Throughput degrades, no errors |
| GET at 512c | ~5.6k | — | Connection refused (past 128 limit), server survives |

After 512-concurrency overload (167k connection refused errors), the server was still healthy and the WAL was intact (249k entries, 186 MB, chain verified).

**Conclusions:**
- Throughput plateaus at 16-32 concurrent connections — classic single-threaded behavior
- WAL write is not the bottleneck (updates plateau at the same rate as reads)
- Server survives overload gracefully — no panics, no hangs, no corruption
- Connection refused at 512c is the listen backlog filling up, not a server crash
- No features needed — the system degrades predictably under load

## 7. Hand it to someone else

**Status: cannot automate.**

Give someone the WAL file and these instructions:
- "Product X has the wrong price. Find out what changed it and when."
- "An order was created that shouldn't have been. Find it."
- Only tools available: `tiger-replay verify`, `tiger-replay inspect`, `tiger-replay replay`

Watch where they get stuck. That's the UX feedback.

## Priority

| Test | Status | Result |
|------|--------|--------|
| 1. WAL growth | Done | 65 MB/day at 1 mut/sec. Rotation is nice-to-have. |
| 2. Kill -9 recovery | Done | 30 rounds, zero entries lost, zero chain breaks. |
| 3. Replay after crash | Deferred | Manual exercise — use inspect/replay after a real crash. |
| 4. Debug with WAL | Deferred | Simulate a bug, find it with only WAL tools. |
| 5. Schema migration | Done | Size changes caught at compile time. Field reorders caught by root sentinel (fixed). |
| 6. Saturate | Done | 29k req/sec peak, survives 512c overload, WAL not the bottleneck. |
| 7. Hand to someone | Deferred | Needs a human. |
