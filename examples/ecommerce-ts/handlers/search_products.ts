import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, RenderContext } from "tiger-web";
import { esc, price } from "tiger-web";

// [route] .search_products
// match GET /products/search
export function route(req: RouteRequest): RouteResult | null {
  const q = new URLSearchParams(req.path.split("?")[1] || "").get("q") || "";
  return { operation: "search_products", id: "0".repeat(32), body: { query: q } };
}

// [prefetch] .search_products
export function prefetch(msg: PrefetchMessage): Record<string, PrefetchQuery> {
  const q = String(msg.body.query || "");
  const results: PrefetchQuery = {
    sql: "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 AND name LIKE ?1 ORDER BY id LIMIT 50",
    params: [`%${q}%`],
    mode: "all",
  };
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
