import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .remove_collection_member
// match DELETE /collections/:id/members/:sub_id
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "remove_collection_member", id: req.params.id, body: { product_id: req.params.sub_id } };
}

// [prefetch] .remove_collection_member
export function prefetch(msg: PrefetchMessage): Record<string, PrefetchQuery> {
  const collection: PrefetchQuery = {
    sql: "SELECT id, name, active FROM collections WHERE id = ?1",
    params: [msg.id],
    mode: "one",
  };
  return { collection };
}

// [handle] .remove_collection_member
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (!ctx.prefetched.collection) return "not_found";
  db.execute(
    "UPDATE collection_members SET removed = 1 WHERE collection_id = ?1 AND product_id = ?2 AND removed = 0",
    [ctx.id, ctx.body.product_id],
  );
  return "ok";
}

// [render] .remove_collection_member
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Removed</div>";
    case "not_found": return '<div class="error">Collection not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
