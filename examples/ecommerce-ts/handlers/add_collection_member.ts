import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .add_collection_member
// match POST /collections/:id/members
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const product_id = String(parsed.product_id || "");
  if (product_id.length !== 32) return null;
  return { operation: "add_collection_member", id: req.params.id, body: { product_id } };
}

// [prefetch] .add_collection_member
export function prefetch(msg: PrefetchMessage): Record<string, PrefetchQuery> {
  return {
    collection: {
      sql: "SELECT id, name, active FROM collections WHERE id = ?1",
      params: [msg.id],
      mode: "one",
    },
  };
}

// [handle] .add_collection_member
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (!ctx.prefetched.collection) return "not_found";
  db.execute(
    "INSERT INTO collection_members (collection_id, product_id, removed) VALUES (?1, ?2, 0) ON CONFLICT(collection_id, product_id) DO UPDATE SET removed = 0",
    [ctx.id, ctx.body.product_id],
  );
  return "ok";
}

// [render] .add_collection_member
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Added</div>";
    case "not_found": return '<div class="error">Collection not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
