# Plan: Consolidate to SHM 1-RT/2-RT as sole sidecar protocol

## Context

Three sidecar protocols coexist, selected by compile-time flags:
- V1 1-CALL over Unix socket (`protocol_v2 = false`)
- V2 4-RT pipelined over SHM (`protocol_v2 = true`, 4-RT stages)
- V2 1-RT/2-RT combined over SHM (current best, behind `protocol_v2 + protocol_v2_shm`)

The 1-RT/2-RT path beats Fastify on every operation (+52% default mix).
The V1 and 4-RT paths are dead code when the flags are enabled. Three
protocol paths triple the maintenance surface, and the flags add
confusion about which mode is "production."

## Goal

Make SHM 1-RT/2-RT the only sidecar protocol. Remove all dead paths.
No feature flags — sidecar mode means SHM 1-RT with automatic 2-RT
fallback. One path to test, one path to optimize, one path to reason about.

## What to delete (~2000 lines)

### Zig server-side

| File | What | Lines |
|---|---|---|
| `sidecar.zig` | V1 1-CALL client, QUERY sub-protocol, state_buf, skip_params | ~330 |
| `sidecar_handlers.zig` | V1 handler dispatch, PrefetchCache, route/prefetch/execute/render delegation | ~350 |
| `sidecar_dispatch.zig` | 4-RT stages: route_pending, route_complete, prefetch_pending, prefetch_complete, sql_executing, sql_complete, handle_pending, render_pending. Also `start_request` (4-RT entry point), `parse_route_result`, `parse_prefetch_result`, `parse_handle_result` | ~200 |
| `framework/server.zig` | V1 dispatch path in `try_dispatch` (the non-v2 branch), `commit_dispatch`, `pipeline_reset` for V1 slots | ~100 |
| `app.zig` | `protocol_v2`, `protocol_v2_shm` flags. `HandlersFor` branches for V1. V1 handler type resolution | ~30 |
| `framework/message_bus.zig` | Sidecar socket connection pool (keep if used for non-sidecar) | ~0-200 |

### TypeScript sidecar-side

| File | What | Lines |
|---|---|---|
| `adapters/call_runtime_v2.ts` | Socket-based V2 sidecar — entire file | ~520 |
| `adapters/call_runtime.ts` | V1 socket sidecar — entire file (if exists) | ~300 |
| `adapters/call_runtime_v2_shm.ts` | Remove 4-RT dispatch functions: `dispatchRoute`, `dispatchPrefetch`, `dispatchHandle`, `dispatchRender`. Remove `requests` map (only used by 4-RT). Keep `dispatchHandleRender`, `dispatchRoutePrefetch` | ~200 |

### Annotation scanner

| What | Lines |
|---|---|
| Remove `@dynamic-prefetch` directive parsing (2-RT is auto-detected) | ~20 |
| Remove `dynamic_prefetch` field from Annotation | ~5 |
| Simplify emitter: no "2-RT (dynamic prefetch)" comment, just "2-RT" | ~5 |

### Build system

| What | Lines |
|---|---|
| Remove `-Dsidecar` flag from `zig build` if SHM is always-on | depends |
| Or: keep `-Dsidecar` but remove `-Dprotocol-v2` concept | ~10 |

## What to keep

- `sidecar_dispatch.zig` stages: `combined_pending`, `combined_complete`, `route_prefetch_pending`, `route_prefetch_complete`, `write_pending`, `write_complete`, `render_complete`
- `start_combined_request` (1-RT entry), `start_request_2rt` (2-RT entry)
- `parse_combined_result`, `parse_route_prefetch_result`
- `dispatchHandleRender`, `dispatchRoutePrefetch` in TS
- SHM bus, C addon, shm_client.ts
- Annotation scanner SQL extraction + `prefetch.generated.zig`
- Prepared statement cache in storage.zig
- `sidecar.zig:skip_params` — still used by `parse_combined_result` for write parsing. Extract to a shared utility or inline.

## Approach

Compiler-driven deletion. Remove a type or field, fix all compilation
errors. Test after each step.

### Step 1: Remove the flag branching

Make `protocol_v2 = true` and `protocol_v2_shm = true` unconditional
when `sidecar_enabled = true`. Remove the `if (App.protocol_v2)` guards
throughout server.zig.

### Step 2: Delete V1 protocol

Delete `sidecar.zig` and `sidecar_handlers.zig`. Fix all imports.
The `skip_params` function needs to move to `protocol.zig` or inline
into `sidecar_dispatch.zig`.

### Step 3: Delete 4-RT stages

Remove 4-RT stages from the Stage enum. Remove `start_request`,
`parse_route_result`, `parse_prefetch_result`, `parse_handle_result`.
Remove 4-RT branches from `on_frame`, `advance`, `invariants`.

### Step 4: Delete socket-based TS sidecars

Delete `call_runtime_v2.ts`, `call_runtime.ts`. Remove 4-RT dispatch
functions from `call_runtime_v2_shm.ts`. Remove `requests` map.

### Step 5: Simplify annotation scanner

Remove `@dynamic-prefetch`. The scanner already auto-detects 2-RT
when extraction fails (note + null spec). The directive is redundant.
Remove `search_products.ts` `@dynamic-prefetch` annotation.

### Step 6: Clean up build flags

Remove `protocol_v2` and `protocol_v2_shm` from app.zig. Sidecar mode
(`-Dsidecar=true`) implies SHM 1-RT/2-RT. One flag, one meaning.

## Verification

After each step:
1. `zig build -Dsidecar=true -Dpipeline-slots=8 -Doptimize=ReleaseSafe` compiles
2. `zig build scan -- examples/ecommerce-ts/handlers/` passes
3. `zig build unit-test` passes
4. Smoke test: curl GET + POST through SHM sidecar
5. Final: `zig build load` benchmark matches pre-consolidation numbers

## Risk

Low. All deleted code is behind compile-time flags that are never
enabled in the consolidated build. The compiler ensures nothing
references deleted types. The benchmark verifies no regression.

The only risk: `sidecar.zig:skip_params` is imported by
`sidecar_dispatch.zig` and `framework/server.zig` for write parsing.
Extract it before deleting the file.
