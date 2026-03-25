import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "tiger-web";
import { esc } from "tiger-web";

// [route] .get_collection
// match GET /collections/:id
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "get_collection", id: req.params.id };
}

// [prefetch] .get_collection
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const collection = db.query("SELECT id, name, active FROM collections WHERE id = ?1", msg.id);
  return { collection };
}

// [handle] .get_collection
export function handle(ctx: HandleContext): string {
  if (!ctx.prefetched.collection) return "not_found";
  return "ok";
}

// [render] .get_collection
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return `<div>Collection: ${esc(ctx.prefetched.collection.name)}</div>`;
    case "not_found": return '<div class="error">Collection not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
