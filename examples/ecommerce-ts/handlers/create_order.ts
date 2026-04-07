import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .create_order
// match POST /orders
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const items = parsed.items;
  if (!Array.isArray(items) || items.length === 0) return null;
  const id = String(parsed.id || "0".repeat(32));
  return { operation: "create_order", id, body: { id, items } };
}

// [prefetch] .create_order
// @param json_array items.product_id
export async function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const items = msg.body.items as Array<{ product_id: string; quantity: number }>;
  const ids = items.map(i => i.product_id);
  const products = await db.queryAll(
    "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id IN (SELECT value FROM json_each(?1))",
    JSON.stringify(ids),
  );
  return { products };
}

// [handle] .create_order
export function handle(ctx: HandleContext, db: WriteDb): string {
  const items = ctx.body.items as Array<{ product_id: string; quantity: number }>;
  const products = (ctx.prefetched.products || []) as any[];

  // Build lookup map from prefetched list.
  const byId = new Map<string, any>();
  for (const p of products) byId.set(p.id, p);

  let total = 0;
  for (let i = 0; i < items.length; i++) {
    const product = byId.get(items[i].product_id);
    if (!product) return "not_found";
    if (!product.active) return "not_found";
    if (product.inventory < items[i].quantity) return "insufficient_inventory";
    total += product.price_cents * items[i].quantity;
  }

  // Deduct inventory.
  for (let i = 0; i < items.length; i++) {
    const product = byId.get(items[i].product_id)!;
    db.execute(
      "UPDATE products SET inventory = ?2, version = ?3 WHERE id = ?1",
      items[i].product_id, product.inventory - items[i].quantity, product.version + 1,
    );
  }

  // Create order.
  db.execute(
    "INSERT INTO orders (id, total_cents, items_len, status, timeout_at) VALUES (?1, ?2, ?3, ?4, ?5)",
    ctx.body.id, total, items.length, "pending", 0,
  );

  // Create order items.
  for (let i = 0; i < items.length; i++) {
    const product = byId.get(items[i].product_id)!;
    db.execute(
      "INSERT INTO order_items (order_id, product_id, name, quantity, price_cents, line_total_cents) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ctx.body.id, items[i].product_id, product.name, items[i].quantity, product.price_cents, product.price_cents * items[i].quantity,
    );
  }

  return "ok";
}

// [render] .create_order
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Order created</div>";
    case "not_found": return '<div class="error">Product not found</div>';
    case "insufficient_inventory": return '<div class="error">Insufficient inventory</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
