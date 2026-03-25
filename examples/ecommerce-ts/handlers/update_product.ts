import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .update_product
// match PUT /products/:id
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const name = String(parsed.name || "");
  if (name.length === 0) return null;
  return {
    operation: "update_product",
    id: req.params.id,
    body: {
      name,
      description: String(parsed.description || ""),
      price_cents: Number(parsed.price_cents ?? 0),
      inventory: Number(parsed.inventory ?? 0),
      version: Number(parsed.version ?? 1),
    },
  };
}

// [prefetch] .update_product
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const product = db.query("SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1", msg.id);
  return { product };
}

// [handle] .update_product
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (!ctx.prefetched.product) return "not_found";
  if (ctx.body.version !== ctx.prefetched.product.version) return "version_conflict";
  db.execute(
    "UPDATE products SET name = ?2, description = ?3, price_cents = ?4, inventory = ?5, version = ?6, active = ?7 WHERE id = ?1",
    [ctx.id, ctx.body.name, ctx.body.description || "", ctx.body.price_cents || 0, ctx.body.inventory || 0, (ctx.prefetched.product.version as number) + 1, true],
  );
  return "ok";
}

// [render] .update_product
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return '<div class="product">Updated</div>';
    case "not_found": return '<div class="error">Product not found</div>';
    case "version_conflict": return '<div class="error">Version conflict</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
