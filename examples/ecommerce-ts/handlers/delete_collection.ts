import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .delete_collection
// match DELETE /collections/:id
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "delete_collection", id: req.params.id };
}

// [prefetch] .delete_collection
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const collection = db.query("SELECT id, name, active FROM collections WHERE id = ?1", msg.id);
  return { collection };
}

// [handle] .delete_collection
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (!ctx.prefetched.collection) return "not_found";
  db.execute("UPDATE collections SET active = ?2 WHERE id = ?1", ctx.id, false);
  return "ok";
}

// [render] .delete_collection
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Deleted</div>";
    case "not_found": return '<div class="error">Collection not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
