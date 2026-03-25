import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, RenderContext } from "tiger-web";

// [route] .logout
// match POST /logout
export function route(_req: RouteRequest): RouteResult | null {
  return { operation: "logout", id: "0".repeat(32) };
}

// [prefetch] .logout
export function prefetch(_msg: PrefetchMessage): Record<string, PrefetchQuery> {
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
