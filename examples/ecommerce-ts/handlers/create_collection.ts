import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "focus";

// [route] .create_collection
// match POST /collections
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const name = String(parsed.name || "");
  if (name.length === 0) return null;
  const id = String(parsed.id || "0".repeat(32));
  return { operation: "create_collection", id, body: { id, name } };
}

// [prefetch] .create_collection
export async function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const existing = await db.query("SELECT id FROM collections WHERE id = ?1", msg.id);
  return { existing };
}

// [handle] .create_collection
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (ctx.prefetched.existing) return "version_conflict";
  db.execute(
    "INSERT INTO collections (id, name, active) VALUES (?1, ?2, ?3)",
    ctx.body.id, ctx.body.name, true,
  );
  return "ok";
}

// [render] .create_collection
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Created</div>";
    case "version_conflict": return '<div class="error">Collection already exists</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
