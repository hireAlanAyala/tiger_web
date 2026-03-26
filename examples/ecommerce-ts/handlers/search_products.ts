import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "tiger-web";
import { esc, price } from "tiger-web";

// [route] .search_products
// match GET /products
export function route(req: RouteRequest): RouteResult | null {
  // Require ?q= — without it, list_products handles GET /products.
  const q = new URLSearchParams(req.path.split("?")[1] || "").get("q") || "";
  if (q.length === 0) return null;
  return { operation: "search_products", id: "0".repeat(32), body: { query: q } };
}

// [prefetch] .search_products
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const q = String(msg.body.query || "");
  const results = db.queryAll("SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 AND name LIKE ?1 ORDER BY id LIMIT 50", `%${q}%`);
  return { results };
}

// [handle] .search_products
export function handle(_ctx: HandleContext): string {
  return "ok";
}

// [render] .search_products
export function render(ctx: RenderContext): string {
  const results = ctx.prefetched.results as unknown[] | null;
  if (!results || results.length === 0) return '<div class="search-results">No results</div>';
  return `<div class="search-results">${results.map((p: any) =>
    `<div class="card"><strong>${esc(p.name)}</strong> &mdash; ${price(p.price_cents)}</div>`
  ).join("")}</div>`;
}
