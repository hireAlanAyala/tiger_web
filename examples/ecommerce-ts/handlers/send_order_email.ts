// Send order confirmation email after order is completed.
// Dispatched from complete_order via worker.send_order_email(order_id, { email }).

// [worker] .send_order_email
// id order_id
export async function send_order_email(ctx: any, db: any) {
  // Read order details for the email body.
  const order = await db.query("SELECT * FROM orders WHERE id = ?", ctx.id);

  // Send the email.
  await new Promise(resolve => setTimeout(resolve, 10));

  return { order_id: ctx.id, email: ctx.body.email, total: order?.total || 0 };
}

// [handle] .send_order_email
export function handle(ctx: any, db: any): string {
  if (ctx.worker_failed) {
    db.execute("UPDATE orders SET email_status = 'failed' WHERE id = ? AND email_status != 'failed'", ctx.id);
    return "failed";
  }
  db.execute("UPDATE orders SET email_status = 'sent' WHERE id = ? AND email_status != 'sent'", ctx.id);
  return "ok";
}

// [render] .send_order_email
export function render(ctx: any): string {
  if (ctx.status === "failed") return `<div class="warning">Email delivery failed.</div>`;
  return "";
}
