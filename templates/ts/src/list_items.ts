import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "focus";
import { esc } from "focus";

// [route] .list_items
// match GET /
export function route(_req: RouteRequest): RouteResult | null {
  return {};
}

// [prefetch] .list_items
export async function prefetch(_msg: PrefetchMessage, db: PrefetchDb) {
  const items = await db.queryAll("SELECT id, name FROM items ORDER BY id LIMIT ?1", 50);
  return { items };
}

// [handle] .list_items
export function handle(_ctx: HandleContext): string {
  return "ok";
}

// [render] .list_items
export function render(ctx: RenderContext): string {
  const items = ctx.prefetched.items as any[] | null;
  if (!items || items.length === 0) return "<p>No items yet. POST / to create one.</p>";
  return "<ul>" + items.map((i: any) => `<li>${esc(i.name)}</li>`).join("") + "</ul>";
}
