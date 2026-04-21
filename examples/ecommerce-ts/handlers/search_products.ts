import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "focus";
import { esc, price } from "focus";

// [route] .search_products
// match GET /products
// query q
export function route(req: RouteRequest): RouteResult | null {
  // q is extracted by the framework from // query annotation into req.params.
  const q = req.params.q || "";
  if (q.length === 0) return null;
  return { id: "0".repeat(32), body: { query: q } };
}

// [prefetch] .search_products
export async function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const q = String(msg.body.query || "");
  const results = await db.queryAll("SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 AND name LIKE ?1 ORDER BY id LIMIT 50", `%${q}%`);
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
