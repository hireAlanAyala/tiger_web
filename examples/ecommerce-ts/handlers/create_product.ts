import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .create_product
// match POST /products
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const name = String(parsed.name || "");
  if (name.length === 0) return null;
  const id = String(parsed.id || "0".repeat(32));
  return {
    operation: "create_product",
    id,
    body: {
      id, name,
      description: String(parsed.description || ""),
      price_cents: Number(parsed.price_cents ?? 0),
      inventory: Number(parsed.inventory ?? 0),
    },
  };
}

// [prefetch] .create_product
export function prefetch(msg: PrefetchMessage): Record<string, PrefetchQuery> {
  return {
    existing: {
      sql: "SELECT id FROM products WHERE id = ?1",
      params: [msg.id],
      mode: "one",
    },
  };
}

// [handle] .create_product
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (ctx.prefetched.existing) return "version_conflict";
  db.execute(
    "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    [ctx.body.id, ctx.body.name, ctx.body.description || "", ctx.body.price_cents || 0, ctx.body.inventory || 0, 1, true],
  );
  return "ok";
}

// [render] .create_product
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "";
    case "version_conflict": return '<div class="error">Product already exists</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
