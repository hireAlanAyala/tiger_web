import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "tiger-web";
import { esc, price } from "tiger-web";

// [route] .get_order
// match GET /orders/:id
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "get_order", id: req.params.id };
}

// [prefetch] .get_order
export async function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const order = await db.query("SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1", msg.id);
  return { order };
}

// [handle] .get_order
export function handle(ctx: HandleContext): string {
  if (!ctx.prefetched.order) return "not_found";
  return "ok";
}

// [render] .get_order
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": {
      const o = ctx.prefetched.order;
      return `<div>Order ${esc(o.id)} &mdash; ${o.status} &mdash; ${price(o.total_cents)}</div>`;
    }
    case "not_found": return '<div class="error">Order not found</div>';
  }
  throw new Error("unreachable: " + ctx.status);
}
