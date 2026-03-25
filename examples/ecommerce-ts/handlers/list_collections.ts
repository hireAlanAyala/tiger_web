import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, RenderContext } from "tiger-web";
import { esc } from "tiger-web";

// [route] .list_collections
// match GET /collections
export function route(_req: RouteRequest): RouteResult | null {
  return { operation: "list_collections", id: "0".repeat(32) };
}

// [prefetch] .list_collections
export function prefetch(_msg: PrefetchMessage): Record<string, PrefetchQuery> {
  return {
    collections: {
      sql: "SELECT id, name, active FROM collections WHERE active = 1 ORDER BY id LIMIT ?1",
      params: [50],
      mode: "all",
    },
  };
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
