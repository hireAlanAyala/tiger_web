import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "tiger-web";
import { esc, price } from "tiger-web";

// [route] .list_products
// match GET /products
// query q
export function route(req: RouteRequest): RouteResult | null {
  // Reject if ?q= is present — search_products handles filtered queries.
  // q is extracted by the framework from // query annotation into req.params.
  if (req.params.q) return null;
  return { operation: "list_products", id: "0".repeat(32) };
}

// [prefetch] .list_products
export async function prefetch(_msg: PrefetchMessage, db: PrefetchDb) {
  const products = await db.queryAll("SELECT id, name, description, price_cents, inventory, version, active FROM products ORDER BY id LIMIT ?1", 50);
  return { products };
}

// [handle] .list_products
export function handle(_ctx: HandleContext): string {
  return "ok";
}

// [render] .list_products
export function render(ctx: RenderContext): string {
  const products = ctx.prefetched.products as unknown[] | null;
  if (!products || products.length === 0) return '<div class="meta">No products</div>';
  return products
    .filter((p: any) => p.active)
    .map((p: any) =>
      `<div class="card"><strong>${esc(p.name)}</strong> &mdash; ${price(p.price_cents)}` +
      ` &mdash; inv: ${p.inventory} &mdash; v${p.version}</div>`)
    .join("");
}
