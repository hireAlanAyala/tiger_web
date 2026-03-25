import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "tiger-web";

// [route] .logout
// match POST /logout
export function route(_req: RouteRequest): RouteResult | null {
  return { operation: "logout", id: "0".repeat(32) };
}

// [prefetch] .logout
export function prefetch(_msg: PrefetchMessage, _db: PrefetchDb) {
  return {};
}

// [handle] .logout
export function handle(_ctx: HandleContext): string {
  // Session clearing is handled by the framework via session_action.
  return "ok";
}

// [render] .logout
export function render(_ctx: RenderContext): string {
  return "<div>Logged out</div>";
}
