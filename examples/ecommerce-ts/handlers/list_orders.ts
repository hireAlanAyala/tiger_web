import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchQuery, HandleContext, RenderContext } from "tiger-web";
import { price } from "tiger-web";

// [route] .list_orders
// match GET /orders
export function route(_req: RouteRequest): RouteResult | null {
  return { operation: "list_orders", id: "0".repeat(32) };
}

// [prefetch] .list_orders
export function prefetch(_msg: PrefetchMessage): Record<string, PrefetchQuery> {
  return {
    orders: {
      sql: "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1",
      params: [50],
      mode: "all",
    },
  };
}

// [handle] .list_orders
export function handle(_ctx: HandleContext): string {
  return "ok";
}

// [render] .list_orders
export function render(ctx: RenderContext): string {
  const orders = ctx.prefetched.orders as unknown[] | null;
  if (!orders || orders.length === 0) return "<div>No orders</div>";
  return orders.map((o: any) =>
    `<div class="card">Order ${o.id.slice(0, 8)}... &mdash; ${o.status} &mdash; ${price(o.total_cents)} &mdash; ${o.items_len} items</div>`
  ).join("");
}
