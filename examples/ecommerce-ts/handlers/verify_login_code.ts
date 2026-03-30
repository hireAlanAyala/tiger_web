import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .verify_login_code
// match POST /login/verify
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const email = String(parsed.email || "");
  const code = String(parsed.code || "");
  if (email.length === 0 || code.length !== 6) return null;
  return { operation: "verify_login_code", id: "0".repeat(32), body: { email, code } };
}

// [prefetch] .verify_login_code
export async function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const login_code = await db.query("SELECT email, code, expires_at FROM login_codes WHERE email = ?1", msg.body.email);
  return { login_code };
}

// [handle] .verify_login_code
export function handle(ctx: HandleContext, db: WriteDb): string {
  const entry = ctx.prefetched.login_code;
  if (!entry) return "invalid_code";
  if (entry.code !== ctx.body.code) return "invalid_code";
  // TODO: purity violation — Date.now() makes handle non-deterministic.
  // Replace with framework-provided timestamp (ctx.fw.now) once available.
  if (entry.expires_at < Date.now()) return "code_expired";
  // Consume the code.
  db.execute("DELETE FROM login_codes WHERE email = ?1", ctx.body.email);
  return "ok";
}

// [render] .verify_login_code
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Verified</div>";
    case "invalid_code": return '<div class="error">Invalid code</div>';
    case "code_expired": return '<div class="error">Code expired</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
