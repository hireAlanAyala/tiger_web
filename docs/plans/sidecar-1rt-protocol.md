# IMPLEMENTED: 1-RT SHM Sidecar Protocol

**Status: Done.** Implemented across sessions 2026-04-06 through 2026-04-08.

## Results

| Workload | Tiger Web | Fastify | Delta |
|---|---|---|---|
| get_product | 98K | 78K | +25% |
| list_products | 48K | 39K | +22% |
| create_product | 59K | 38K | +57% |
| default mix | 57K | 38K | +52% |

## Architecture

1-RT for 20/22 operations (static SQL extracted at build time):
- Server routes natively (compiled route table)
- Server executes prefetch SQL (prepared statement cache)
- Server writes CALL directly to SHM slot (zero-copy)
- Sidecar runs handle + render, writes RESULT
- Server commits writes + sends HTTP response

2-RT fallback for 2 operations (dynamic SQL):
- `create_order`: loop-based N queries
- `search_products`: LIKE param with template literal

## Key files

- `annotation_scanner.zig` — SQL extraction, `@param`, `@dynamic-prefetch`
- `generated/prefetch.generated.zig` — comptime prefetch specs per operation
- `sidecar_dispatch.zig` — 1-RT + 2-RT stage machines
- `framework/server.zig` — `try_dispatch_1rt`, `process_route_prefetch_complete`
- `framework/shm_bus.zig` — `get_slot_request_buf`, `finalize_slot_send`
- `adapters/call_runtime_v2_shm.ts` — `dispatchHandleRender`, `dispatchRoutePrefetch`
- `storage.zig` — `raw_cache_get/put` (prepared statement cache)

## Remaining work

- io_uring unified wait (replace busy-poll) — see todo.md ticket
- 1-core VPS performance (2.7K vs Fastify's 37K on 1 core)
