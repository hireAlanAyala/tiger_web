import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .request_login_code
// match POST /login/request
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const email = String(parsed.email || "");
  if (email.length === 0) return null;
  return { operation: "request_login_code", id: "0".repeat(32), body: { email } };
}

// [prefetch] .request_login_code
export function prefetch(_msg: PrefetchMessage): Record<string, PrefetchQuery> {
  return {};
}

// [handle] .request_login_code
export function handle(ctx: HandleContext, db: WriteDb): string {
  // TODO: purity violation — Math.random() and Date.now() make handle
  // non-deterministic. Replace with framework-provided PRNG and timestamp
  // (ctx.fw.now, ctx.fw.random) once the TS SDK exposes them.
  const code = String(Math.floor(100000 + Math.random() * 900000));
  const expires_at = Date.now() + 600_000; // 10 minutes
  db.execute(
    "INSERT INTO login_codes (email, code, expires_at) VALUES (?1, ?2, ?3) ON CONFLICT(email) DO UPDATE SET code = ?2, expires_at = ?3",
    [ctx.body.email, code, expires_at],
  );
  return "ok";
}

// [render] .request_login_code
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Code sent</div>";
  }
}
