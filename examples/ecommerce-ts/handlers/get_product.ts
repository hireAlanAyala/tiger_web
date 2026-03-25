import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, RenderContext } from "tiger-web";
import { esc, price } from "tiger-web";

// [route] .get_product
// match GET /products/:id
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "get_product", id: req.params.id };
}

// [prefetch] .get_product
export function prefetch(msg: PrefetchMessage): Record<string, PrefetchQuery> {
  const product: PrefetchQuery = {
    sql: "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1",
    params: [msg.id],
    mode: "one",
  };
  return { product };
}

// [handle] .get_product
export function handle(ctx: HandleContext): string {
  if (!ctx.prefetched.product) return "not_found";
  if (!ctx.prefetched.product.active) return "not_found";
  return "ok";
}

// [render] .get_product
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": {
      const p = ctx.prefetched.product;
      return `<div class="card"><strong>${esc(p.name)}</strong> &mdash; ${price(p.price_cents)}` +
        ` &mdash; inv: ${p.inventory} &mdash; v${p.version}` +
        (!p.active ? ` <span class="error">[inactive]</span>` : ``) +
        `<div class="meta">${p.id}</div>` +
        (p.description ? `<div class="meta">${esc(p.description)}</div>` : ``) +
        `</div>`;
    }
    case "not_found":
      return '<div class="error">Product not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
