import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .transfer_inventory
// match POST /products/:id/transfer-inventory/:sub_id
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const quantity = Number(parsed.quantity ?? 0);
  if (quantity <= 0) return null;
  return {
    operation: "transfer_inventory",
    id: req.params.id,
    body: { target_id: req.params.sub_id, quantity },
  };
}

// [prefetch] .transfer_inventory
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const source = db.query("SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1", msg.id);
  const target = db.query("SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1", msg.body.target_id);
  return { source, target };
}

// [handle] .transfer_inventory
export function handle(ctx: HandleContext, db: WriteDb): string {
  const source = ctx.prefetched.source;
  const target = ctx.prefetched.target;
  if (!source || !target) return "not_found";
  if (!source.active || !target.active) return "not_found";
  const qty = ctx.body.quantity as number;
  if (source.inventory < qty) return "insufficient_inventory";
  db.execute(
    "UPDATE products SET inventory = ?2, version = ?3 WHERE id = ?1",
    ctx.id, source.inventory - qty, source.version + 1,
  );
  db.execute(
    "UPDATE products SET inventory = ?2, version = ?3 WHERE id = ?1",
    ctx.body.target_id, target.inventory + qty, target.version + 1,
  );
  return "ok";
}

// [render] .transfer_inventory
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Transferred</div>";
    case "not_found": return '<div class="error">Product not found</div>';
    case "insufficient_inventory": return '<div class="error">Insufficient inventory</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
