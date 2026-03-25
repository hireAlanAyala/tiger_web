import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, WriteDb, RenderContext } from "tiger-web";
import { esc, price } from "tiger-web";

// [route] .complete_order
// match POST /orders/:id/complete
export function route(req: RouteRequest): RouteResult | null {
  const parsed = JSON.parse(req.body || "{}");
  const result = String(parsed.result || "");
  if (result !== "confirmed" && result !== "failed") return null;
  return {
    operation: "complete_order",
    id: req.params.id,
    body: { result, payment_ref: String(parsed.payment_ref || "") },
  };
}

// [prefetch] .complete_order
export function prefetch(msg: PrefetchMessage): Record<string, PrefetchQuery> {
  return {
    order: {
      sql: "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1",
      params: [msg.id],
      mode: "one",
    },
  };
}

// [handle] .complete_order
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (!ctx.prefetched.order) return "not_found";
  if (ctx.prefetched.order.status !== "pending") return "order_not_pending";
  // TODO: restore inventory if failed, set payment_ref
  db.execute(
    "UPDATE orders SET status = ?2 WHERE id = ?1",
    [ctx.id, ctx.body.result],
  );
  return "ok";
}

// [render] .complete_order
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": {
      const o = ctx.prefetched.order;
      return `<div class="card">Order ${esc(o.id.slice(0, 8))}... &mdash; ${o.status} &mdash; ${price(o.total_cents)}</div>`;
    }
    case "not_found": return '<div class="error">Order not found</div>';
    case "order_not_pending": return '<div class="error">Order is not pending</div>';
  }
}
