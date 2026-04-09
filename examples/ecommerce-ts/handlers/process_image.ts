// Resize and optimize a product image after upload.
// Dispatched from update_product via worker.process_image(product_id, { url }).

// [worker] .process_image
// id product_id
export async function process_image(ctx: any, db: any) {
  // Can read current product state if needed.
  const product = await db.query("SELECT * FROM products WHERE id = ?", ctx.id);

  // Call external image processing service.
  await new Promise(resolve => setTimeout(resolve, 50));
  const thumbnail = `https://cdn.example.com/${ctx.id}/thumb.jpg`;
  const full = `https://cdn.example.com/${ctx.id}/full.jpg`;

  return { product_id: ctx.id, thumbnail_url: thumbnail, full_url: full };
}

// [handle] .process_image
export function handle(ctx: any, db: any): string {
  if (ctx.worker_failed) {
    db.execute("UPDATE products SET image_status = 'failed' WHERE id = ? AND image_status != 'failed'", ctx.id);
    return "failed";
  }
  db.execute(
    "UPDATE products SET thumbnail_url = ?, image_url = ?, image_status = 'ready' WHERE id = ? AND image_status != 'ready'",
    ctx.body.thumbnail_url, ctx.body.full_url, ctx.id);
  return "ok";
}

// [render] .process_image
export function render(ctx: any): string {
  if (ctx.status === "failed") return `<div class="error">Image processing failed.</div>`;
  return `<img src="${ctx.body.thumbnail_url}" alt="Product image ready">`;
}
