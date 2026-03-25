import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .delete_product
// match DELETE /products/:id
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "delete_product", id: req.params.id };
}

// [prefetch] .delete_product
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const product = db.query("SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1", msg.id);
  return { product };
}

// [handle] .delete_product
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (!ctx.prefetched.product) return "not_found";
  if (!ctx.prefetched.product.active) return "not_found";
  db.execute(
    "UPDATE products SET active = ?2 WHERE id = ?1",
    ctx.id, false,
  );
  return "ok";
}

// [render] .delete_product
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return '<div class="product">Deleted</div>';
    case "not_found": return '<div class="error">Product not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
