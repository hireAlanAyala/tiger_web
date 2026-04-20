import type { RouteRequest, RouteResult, HandleContext, WriteDb, RenderContext } from "focus";

// [route] .create_item
// match POST /
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const name = String(parsed.name || "");
  if (!name) return null;
  const id = String(parsed.id || "0".repeat(32));
  return { operation: "create_item", id, body: { id, name } };
}

// [prefetch] .create_item
export async function prefetch() { return {}; }

// [handle] .create_item
export function handle(ctx: HandleContext, db: WriteDb): string {
  db.execute("INSERT OR IGNORE INTO items (id, name) VALUES (?1, ?2)", ctx.body.id, ctx.body.name);
  return "ok";
}

// [render] .create_item
export function render(_ctx: RenderContext): string {
  return "<p>Created.</p>";
}
