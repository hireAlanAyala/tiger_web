# Stress Tests

Scenarios designed to expose framework limitations before users hit them. Each scenario pushes a specific primitive to its edge.

## 1. Infinite scroll

Exposes pagination, HTML swapping, and memory pressure.

- Page loads first 20 products. Client scrolls, requests next 20 via SSE or HTTP.
- Does the prefetch/render pipeline handle offset+limit cleanly, or does it assume full-list fetches?
- What happens when a mutation inserts a product while the user is mid-scroll? Does the list shift, duplicate, or gap?
- SSE partial swaps: appending to a list vs replacing it. Does `sse.append` handle scroll position? Does the client framework (Datastar/htmx) handle duplicate IDs when a shifted item appears in two pages?
- Memory: prefetch returns fixed-size arrays. Infinite scroll implies unbounded data. How does the Prefetch struct handle "page N of M" without allocating?

## 2. Optimized queries vs sse.sync

Exposes the cost of `sse.sync` and whether targeted queries are better.

- `sse.sync("/dashboard")` re-runs the full dashboard prefetch (5 queries). Measure latency per sync under load.
- Compare: `sse.replace("#product-list", html)` where the mutation's render already has the data from its own prefetch. Zero extra queries.
- At what point does `sse.sync` become the bottleneck? 10 concurrent SSE subscribers? 100? 1000?
- Can the framework detect when `sse.sync` is called and the data is already available in the current prefetch? Could it short-circuit the re-query?
- Measure: time from mutation commit to SSE delivery for sync vs replace.

## 3. SSE fan-out load testing

Exposes connection limits and broadcast overhead.

- N users all watching the same dashboard via SSE. One user creates a product. How long until all N see the update?
- Test N = 10, 100, 500, 1000. Measure: time to last delivery, CPU per broadcast, memory per SSE connection.
- What happens when an SSE connection is slow (congested client)? Does it block other subscribers? Does the framework buffer, drop, or close?
- What happens when a subscriber disconnects mid-broadcast? Does the framework detect it on the current tick or next?
- Single-threaded: all SSE writes happen on one thread. At what N does the broadcast loop starve HTTP request processing?

## 4. Multi-tenant isolation

From todo: "Stressor: multi-tenant user."

- Tenant A and Tenant B share the server. Tenant A creates a product. Does Tenant B's SSE connection receive the update?
- `sse.sync("/dashboard")` — does it sync for all users or only the requester's tenant? The route is the same; the data should differ.
- Prefetch must be tenant-scoped. How does the auth identity flow into SSE re-renders triggered by `sse.sync`? The original mutation has auth context, but the sync'd re-render runs for a different user's connection.

## 5. Worker under pressure

- Worker polls for pending orders. 100 orders created in 1 second. Worker processes them sequentially (external API call per order). How far does the queue back up?
- Worker crashes mid-processing. Orders stay "pending" in storage. Worker restarts, re-polls, retries. Does the external API get double-called? Is the operation idempotent?
- Worker is slower than mutation rate. Pending queue grows. Does the server's list query degrade? Does the polling response get larger?

## 6. ~~Prefetch read / handle write boundary~~ — DONE

Scanner enforces prefetch SQL must be SELECT, handle SQL must be
INSERT/UPDATE/DELETE. ReadView/WriteView enforce at runtime.
annotation_scanner.zig validates at build time.

## 7. Storage retry limits

From todo: "storage can retry forever on err, we should add an upper cap."

- Prefetch returns null on storage busy → framework retries next tick. What if storage is permanently busy? The connection sits in `.ready` forever.
- Add a retry cap. After N retries, return a storage error status. Measure: what's a reasonable N? How does it interact with connection timeouts?

## 8. Render without a framework

From todo: "write vanilla html in render without a string and the compiler turns it to datastar so there's no api to learn."

- Can the render function return plain HTML and the framework automatically wraps it for SSE delivery?
- Does the developer need to know Datastar/htmx, or can the framework abstract it?
- Test: render returns `<div id="product-list">...</div>`, framework figures out it's a partial swap targeting `#product-list`.
