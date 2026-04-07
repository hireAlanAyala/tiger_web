# Next session: debug 1-RT keep-alive hang

## What works
- Single curl requests: POST create_product, GET list_products, GET get_product — all through 1-RT
- Annotation scanner extracts SQL for 18/20 handlers
- `prefetch.generated.zig` has comptime specs
- Server does native routing + prefetch SQL + combined CALL
- Sidecar `dispatchHandleRender` runs handle+render, returns combined RESULT
- Writes work: POST creates product, next GET sees it

## What's broken
Keep-alive connections hang after the first request. The second request on the same connection never gets dispatched. `tiger-load` hangs during seed phase (even with 1 connection, 2 products).

## Likely root cause
After the 1-RT response is sent (`render_complete` → `process_v2_completions` → `set_response` → `send_complete`), the connection goes back to receiving. If the client already sent the next request (HTTP pipelining or keep-alive), `try_parse_request` fires and the connection becomes `.ready`. But `on_ready_fn` calls `try_dispatch` → `try_dispatch_v2` → `try_dispatch_1rt`.

The 1-RT path does native route matching using `inline for (gen.routes)` which runs at comptime. But it also calls `storage.query_raw` for prefetch SQL. If the state machine's storage isn't in a valid state for reads at this point (e.g., inside a batch transaction from the previous request's write), the query might fail silently and return false, causing the 1-RT path to fall through to 4-RT, which sends a route CALL. But the connection is marked as already dispatched...

## Debug steps
1. Add `--log-debug` and check if `try_dispatch_1rt` returns true or false for the second request
2. Check if `connection_dispatched(conn)` returns true (preventing re-dispatch)
3. Check if the 4-RT fallback path succeeds for the second request
4. Check `process_v2_completions` → `resume_suspended` interaction — does the connection get suspended but never resumed?

## To benchmark (once fixed)
```bash
# Enable flags
# app.zig: protocol_v2 = true, protocol_v2_shm = true

rm -rf .zig-cache/ zig-out/
./zig/zig build -Dsidecar=true -Dsidecar-count=1 -Dpipeline-slots=8 -Doptimize=ReleaseSafe

rm -f /dev/shm/tiger-* tiger_web.wal
zig-out/bin/tiger-web start --port=9877 --db=/tmp/bench.db &
cd examples/ecommerce-ts && npx tsx ../../adapters/call_runtime_v2_shm.ts "tiger-$!" 8 &

# Small seed, then reads
zig-out/bin/tiger-load --port=9877 --connections=64 --requests=50000 --ops=list_products:50,get_product:50
```

## Target
42K req/s with 1-RT. At ~17µs per handle+render call, theoretical: 59K. With pipeline: 42K+ realistic.
