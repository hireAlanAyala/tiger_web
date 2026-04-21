import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "focus";

// [route] .page_load_login
// match GET /login
export function route(_req: RouteRequest): RouteResult | null {
  return { operation: "page_load_login", id: "0".repeat(32) };
}

// [prefetch] .page_load_login
export async function prefetch(_msg: PrefetchMessage, _db: PrefetchDb) {
  return {};
}

// [handle] .page_load_login
export function handle(_ctx: HandleContext): string {
  return "ok";
}

// [render] .page_load_login
export function render(_ctx: RenderContext): string {
  return "<div>Login</div>";
}
