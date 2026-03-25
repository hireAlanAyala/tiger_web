import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, RenderContext } from "tiger-web";
import { esc, price } from "tiger-web";

// [route] .page_load_dashboard
// match GET /
export function route(_req: RouteRequest): RouteResult | null {
  return { operation: "page_load_dashboard", id: "0".repeat(32) };
}

// [prefetch] .page_load_dashboard
export function prefetch(_msg: PrefetchMessage): Record<string, PrefetchQuery> {
  const products: PrefetchQuery = {
    sql: "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 ORDER BY id LIMIT ?1",
    params: [50],
    mode: "all",
  };
  const collections: PrefetchQuery = {
    sql: "SELECT id, name, active FROM collections WHERE active = 1 ORDER BY id LIMIT ?1",
    params: [50],
    mode: "all",
  };
  const orders: PrefetchQuery = {
    sql: "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1",
    params: [50],
    mode: "all",
  };
  return { products, collections, orders };
}

// [handle] .page_load_dashboard
export function handle(_ctx: HandleContext): string {
  return "ok";
}

// [render] .page_load_dashboard
export function render(ctx: RenderContext): string {
  const products = (ctx.prefetched.products || []) as any[];
  const collections = (ctx.prefetched.collections || []) as any[];
  const orders = (ctx.prefetched.orders || []) as any[];

  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Tiger Web</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: system-ui, sans-serif; background: #f5f5f5; color: #333; padding: 20px; }
h1 { margin-bottom: 16px; font-size: 22px; }
h2 { margin: 20px 0 8px; font-size: 16px; border-bottom: 1px solid #ccc; padding-bottom: 4px; }
.card { background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: 12px; margin: 8px 0; }
.card .meta { font-size: 12px; color: #888; }
.error { color: #f44; }
.cols { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
</style>
</head>
<body>
<h1>Tiger Web</h1>
<div class="cols">
<div>
<section>
<h2>Products</h2>
${products.length === 0 ? '<div class="card">No products</div>' :
  products.map(p =>
    `<div class="card"><strong>${esc(p.name)}</strong> &mdash; ${price(p.price_cents)} &mdash; inv: ${p.inventory} &mdash; v${p.version}<div class="meta">${p.id}</div></div>`
  ).join("\n")}
</section>
</div>
<div>
<section>
<h2>Collections</h2>
${collections.length === 0 ? '<div class="card">No collections</div>' :
  collections.map((c: any) =>
    `<div class="card"><strong>${esc(c.name)}</strong><div class="meta">${c.id}</div></div>`
  ).join("\n")}
</section>
<section>
<h2>Orders</h2>
${orders.length === 0 ? '<div class="card">No orders</div>' :
  orders.map((o: any) =>
    `<div class="card">Order <strong>${o.id.slice(0, 8)}...</strong> &mdash; ${o.status} &mdash; ${price(o.total_cents)} &mdash; ${o.items_len} items</div>`
  ).join("\n")}
</section>
</div>
</div>
</body>
</html>`;
}
