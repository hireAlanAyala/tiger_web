# Cursor Pagination

Every list endpoint must be paginated. The framework enforces this:
`query_all` requires LIMIT in the SQL, and render output that exceeds
the send buffer panics with an actionable message.

## How it works

Pagination uses **cursor-based** iteration. The cursor is the UUID of
the last item on the current page. The next request passes it back,
and the query picks up where it left off.

```
GET /products                → page 1 (no cursor)
GET /products?cursor=<uuid>  → page 2 (cursor = last item from page 1)
```

The client never constructs cursor values. The server embeds the
cursor in a load-more element that triggers the next fetch
automatically.

## Example: list_products

### Route

Parse the cursor from query params. Zero means first page.

```zig
// [route] .list_products
// match GET /products
// query cursor
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const cursor: u128 = if (params.get("cursor")) |c|
        t.parse_uuid(c) orelse return null
    else
        0;
    var lp = std.mem.zeroes(t.ListParams);
    lp.cursor = cursor;
    return t.Message.init(.list_products, 0, 0, lp);
}
```

### Prefetch

When cursor is non-zero, add `WHERE id > ?cursor` to skip past
already-seen items. Always include `LIMIT` — `query_all` enforces
this at comptime.

```zig
const page_size = 10;

// [prefetch] .list_products
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    const params = msg.event();
    if (params.cursor != 0) {
        return .{ .products = storage.query_all(t.ProductRow, page_size,
            "SELECT id, name, description, price_cents, inventory, version, active
             FROM products WHERE id > ?1 ORDER BY id LIMIT ?2;",
            .{ params.cursor, @as(u32, page_size) }) };
    }
    return .{ .products = storage.query_all(t.ProductRow, page_size,
        "SELECT id, name, description, price_cents, inventory, version, active
         FROM products ORDER BY id LIMIT ?1;",
        .{@as(u32, page_size)}) };
}
```

### Render

Render the items, then append a load-more sentinel if there might be
more pages. The sentinel uses Datastar's `data-on-intersect` — when
the user scrolls to it, Datastar fires the next SSE request
automatically.

```zig
// [render] .list_products
pub fn render(ctx: Context) []const u8 {
    const products = (ctx.prefetched.products orelse
        return "<div class=\"meta\">No products</div>").slice();
    if (products.len == 0) return "<div class=\"meta\">No products</div>";

    var pos: usize = 0;
    for (products) |*p| {
        pos += render_product_card(ctx.render_buf[pos..], p);
    }

    // Full page = probably more items. Append a sentinel that
    // triggers the next fetch when the user scrolls to it.
    if (products.len == page_size) {
        const last_id = products[products.len - 1].id;
        pos += h.raw(ctx.render_buf[pos..], "<div data-on-intersect=\"@get('/products?cursor=");
        pos += h.uuid(ctx.render_buf[pos..], last_id);
        pos += h.raw(ctx.render_buf[pos..], "')\" ></div>");
    }

    return ctx.render_buf[0..pos];
}
```

## Why cursor, not offset

| | Cursor (`WHERE id > ?`) | Offset (`OFFSET ?`) |
|---|---|---|
| Performance | O(1) with index | O(n) — scans skipped rows |
| Stability | Stable under inserts/deletes | Rows shift — duplicates or gaps |
| State | Stateless — cursor is in the URL | Stateless, but fragile |
| Bookmarkable | Yes | Technically, but breaks on mutation |

## Safeguards

The framework provides two compile/runtime checks so you can't
accidentally produce an unbounded response:

1. **`query_all` requires LIMIT.** If you forget it, compilation fails:
   ```
   error: query_all requires LIMIT in SQL — unbounded SELECT is not allowed
   ```

2. **Render overflow panics with guidance.** If rendered HTML exceeds
   the send buffer:
   ```
   panic: render output exceeded send buffer (256KB) — reduce items per page or shrink templates
   ```
