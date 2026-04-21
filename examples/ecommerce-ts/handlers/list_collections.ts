import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "focus";
import { esc } from "focus";

// [route] .list_collections
// match GET /collections
export function route(_req: RouteRequest): RouteResult | null {
  return {};
}

// [prefetch] .list_collections
export async function prefetch(_msg: PrefetchMessage, db: PrefetchDb) {
  const collections = await db.queryAll("SELECT id, name, active FROM collections WHERE active = 1 ORDER BY id LIMIT ?1", 50);
  return { collections };
}

// [handle] .list_collections
export function handle(_ctx: HandleContext): string {
  return "ok";
}

// [render] .list_collections
export function render(ctx: RenderContext): string {
  const items = ctx.prefetched.collections as unknown[] | null;
  if (!items || items.length === 0) return "<div>No collections</div>";
  return items.map((c: any) => `<div class="card">${esc(c.name)}</div>`).join("");
}
