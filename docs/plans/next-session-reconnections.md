# Next session: investigate reconnections under load

## Symptom
Under load (tiger-load with 64 connections), the load driver sees 100+ reconnections. The server stays alive but drops connections. This causes the load driver to panic on `close(fd)` for bad file descriptors.

## When it happens
- Default ops mix with all operation types
- NOT with reads-only (list_products:50,get_product:50)
- Likely triggered by no-SQL handlers (page_load_login, logout) going through 1-RT with empty body responses

## Possible cause
The 1-RT path for no-SQL handlers sends handle_render with 0 row sets. The sidecar responds with HTML. The response encoding in process_v2_completions may set keep_alive = false for empty prefetch results, causing the server to close the connection after each response.

## Debug steps
1. Enable `--log-debug` and check connection close reasons
2. Check if `conn.keep_alive` is set correctly for 1-RT responses
3. Compare connection lifecycle between reads-only (no reconnections) and default mix (reconnections)
4. Check `encode_response` for edge cases with empty HTML or empty prefetch

## Impact
Reconnections reduce throughput — each reconnection is a TCP handshake + HTTP parse overhead. Fixing this should bring the default mix closer to reads-only throughput.
