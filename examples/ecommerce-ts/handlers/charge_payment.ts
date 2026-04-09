// Charge payment for an order.
// Dispatched from create_order handler via worker.charge_payment(order_id, { amount }).

import type { HandleContext } from '../../../generated/types.generated.ts';

// [worker] .charge_payment
// id order_id
export async function charge_payment(ctx: any, db: any) {
  // Worker has full async IO + database read access.
  const order = await db.query("SELECT * FROM orders WHERE id = ?", ctx.id);

  // Call external payment API.
  const charge = await (async () => {
    // Simulate Stripe API call.
    await new Promise(resolve => setTimeout(resolve, 10));
    return { id: `ch_${Date.now()}`, status: "succeeded" };
  })();

  return { order_id: ctx.id, charge_id: charge.id, amount: ctx.body.amount };
}

// [handle] .charge_payment
export function handle(ctx: HandleContext, db: any): string {
  if (ctx.worker_failed) {
    db.execute("UPDATE orders SET payment_status = 'failed' WHERE id = ? AND payment_status != 'failed'", ctx.id);
    return "failed";
  }
  db.execute(
    "UPDATE orders SET payment_status = 'paid', charge_id = ? WHERE id = ? AND payment_status != 'paid'",
    ctx.body.charge_id, ctx.id);
  return "ok";
}

// [render] .charge_payment
export function render(ctx: any): string {
  if (ctx.status === "failed") {
    return `<div class="error">Payment failed for order ${ctx.id}.</div>`;
  }
  return `<div>Payment confirmed for order ${ctx.id}.</div>`;
}
