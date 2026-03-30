import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "tiger-web";

// [route] .get_product_inventory
// match GET /products/:id/inventory
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "get_product_inventory", id: req.params.id };
}

// [prefetch] .get_product_inventory
export async function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const product = await db.query("SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1", msg.id);
  return { product };
}

// [handle] .get_product_inventory
export function handle(ctx: HandleContext): string {
  if (!ctx.prefetched.product) return "not_found";
  if (!ctx.prefetched.product.active) return "not_found";
  return "ok";
}

// [render] .get_product_inventory
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return `<div class="inventory">${ctx.prefetched.product.inventory}</div>`;
    case "not_found": return '<div class="error">Product not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
