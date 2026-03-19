// Product handlers — each operation groups route → handle → render.

import type {
  Request,
  Route,
  Response,
  Context,
  Product,
} from "tiger-web";
import { assert } from "tiger-web";

// ========================== create_product ==========================

// [route] .create_product
export function routeCreateProduct(req: Request): Route<Product> | null {
  if (req.method !== "post" || req.path !== "/products") return null;
  const parsed = JSON.parse(req.body || "{}");
  const id = parsed.id || "0".repeat(32);
  const body = parseProduct(parsed, id);
  if (body === null) return null;
  return { operation: "create_product", id, body };
}

// [handle] .create_product
export function handleCreateProduct(ctx: Context, body: Product): Response {
  if (ctx.product !== null) return { status: "version_conflict", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .create_product
export function renderCreateProduct(status: string, ctx: Context): string {
  if (status !== "ok") return `<div class="error">${esc(status)}</div>`;
  return `<div class="product">Created</div>`;
}

// ========================== get_product ==========================

// [route] .get_product
export function routeGetProduct(req: Request): Route | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "get") return null;
  return { operation: "get_product", id: match[1] };
}

// [handle] .get_product
export function handleGetProduct(ctx: Context): Response {
  if (ctx.product === null) return { status: "not_found", writes: [] };
  if (!ctx.product.flags.active) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .get_product
export function renderGetProduct(status: string, ctx: Context): string {
  if (status !== "ok") return `<div class="error">${esc(status)}</div>`;
  const p = assertProduct(ctx);
  return `<div class="card">` +
    `<h3>${esc(p.name)}</h3>` +
    `<p>$${(p.price_cents / 100).toFixed(2)}</p>` +
    `<p>Inventory: ${p.inventory}</p>` +
    `<p>Version: ${p.version}</p>` +
    (!p.flags.active ? `<span>[inactive]</span>` : ``) +
    `</div>`;
}

// ========================== list_products ==========================

// [route] .list_products
export function routeListProducts(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/products") return null;
  return { operation: "list_products", id: "0".repeat(32) };
}

// [handle] .list_products
export function handleListProducts(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .list_products
export function renderListProducts(status: string, ctx: Context): string {
  const items = ctx.product_list.items;
  return `<div class="products">${items.map(p => `<div>${esc(p.name)}</div>`).join("")}</div>`;
}

// ========================== update_product ==========================

// [route] .update_product
export function routeUpdateProduct(req: Request): Route<Product> | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "put") return null;
  const parsed = JSON.parse(req.body || "{}");
  const body = parseProduct(parsed, match[1]);
  if (body === null) return null;
  return { operation: "update_product", id: match[1], body };
}

// [handle] .update_product
export function handleUpdateProduct(ctx: Context, body: Product): Response {
  if (ctx.product === null) return { status: "not_found", writes: [] };
  if (body.version !== ctx.product.version) return { status: "version_conflict", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .update_product
export function renderUpdateProduct(status: string, ctx: Context): string {
  if (status !== "ok") return `<div class="error">${esc(status)}</div>`;
  return `<div class="product">Updated</div>`;
}

// ========================== delete_product ==========================

// [route] .delete_product
export function routeDeleteProduct(req: Request): Route | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "delete") return null;
  return { operation: "delete_product", id: match[1] };
}

// [handle] .delete_product
export function handleDeleteProduct(ctx: Context): Response {
  if (ctx.product === null) return { status: "not_found", writes: [] };
  if (!ctx.product.flags.active) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .delete_product
export function renderDeleteProduct(status: string, ctx: Context): string {
  if (status !== "ok") return `<div class="error">${esc(status)}</div>`;
  return `<div class="product">Deleted</div>`;
}

// ========================== get_product_inventory ==========================

// [route] .get_product_inventory
export function routeGetProductInventory(req: Request): Route | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})\/inventory$/);
  if (!match || req.method !== "get") return null;
  return { operation: "get_product_inventory", id: match[1] };
}

// [handle] .get_product_inventory
export function handleGetProductInventory(ctx: Context): Response {
  if (ctx.product === null) return { status: "not_found", writes: [] };
  if (!ctx.product.flags.active) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .get_product_inventory
export function renderGetProductInventory(status: string, ctx: Context): string {
  if (status !== "ok") return `<div class="error">${esc(status)}</div>`;
  const p = assertProduct(ctx);
  return `<div class="inventory">${p.inventory}</div>`;
}

// ========================== search_products ==========================

// [route] .search_products
export function routeSearchProducts(req: Request): Route | null {
  if (req.method !== "get" || !req.path.startsWith("/products/search")) return null;
  return { operation: "search_products", id: "0".repeat(32) };
}

// [handle] .search_products
export function handleSearchProducts(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .search_products
export function renderSearchProducts(status: string, ctx: Context): string {
  return `<div class="search-results">Search results</div>`;
}

// ========================== boundary validation ==========================

function parseProduct(parsed: Record<string, unknown>, id: string): Product | null {
  const name = String(parsed.name || "");
  const description = String(parsed.description || "");
  const price_cents = Number(parsed.price_cents ?? 0);
  const inventory = Number(parsed.inventory ?? 0);
  const version = Number(parsed.version ?? 1);

  // Domain rules — serde handles max length, these are business logic.
  if (name.length === 0) return null;
  if (!Number.isInteger(price_cents) || price_cents < 0) return null;
  if (!Number.isInteger(inventory) || inventory < 0) return null;
  if (!Number.isInteger(version) || version < 1) return null;

  return { id, name, description, price_cents, inventory, version, flags: { active: true } };
}

// ========================== render assertions ==========================

function assertProduct(ctx: Context): Product {
  assert(ctx.product !== null, "render: product is null after ok status");
  return ctx.product;
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
