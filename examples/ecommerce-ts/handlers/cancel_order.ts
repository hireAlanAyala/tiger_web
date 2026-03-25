import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, WriteDb, RenderContext } from "tiger-web";
import { esc } from "tiger-web";

// [route] .cancel_order
// match POST /orders/:id/cancel
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "cancel_order", id: req.params.id };
}

// [prefetch] .cancel_order
export function prefetch(msg: PrefetchMessage): Record<string, PrefetchQuery> {
  return {
    order: {
      sql: "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1",
      params: [msg.id],
      mode: "one",
    },
  };
}

// [handle] .cancel_order
export function handle(ctx: HandleContext, db: WriteDb): string {
  if (!ctx.prefetched.order) return "not_found";
  if (ctx.prefetched.order.status !== "pending") return "order_not_pending";
  db.execute("UPDATE orders SET status = ?2 WHERE id = ?1", [ctx.id, "cancelled"]);
  return "ok";
}

// [render] .cancel_order
export function render(ctx: RenderContext): string {
  switch (ctx.status) {
    case "ok": return "<div>Cancelled</div>";
    case "not_found": return '<div class="error">Order not found</div>';
    case "order_not_pending": return '<div class="error">Order is not pending</div>';
    default: return `<div class="error">${esc(ctx.status)}</div>`;
  }
}
