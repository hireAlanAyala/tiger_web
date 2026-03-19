// Product handlers — translate, execute, render.

import type {
  TranslateRequest,
  TranslateResponse,
  PrefetchCache,
  Product,
} from "../../generated/types.generated.ts";
import { writeProduct } from "../../generated/types.generated.ts";

// ---------------------------------------------------------------------------
// Translate
// ---------------------------------------------------------------------------

// [translate] .create_product
export function translateCreateProduct(req: TranslateRequest): TranslateResponse {
  if (req.method !== "post" || req.path !== "/products") {
    return notFound();
  }
  const parsed = JSON.parse(req.body || "{}");
  const id = parsed.id || "0".repeat(32);
  const product = makeProduct(parsed, id);
  const body = new Uint8Array(672);
  writeProduct(body, 0, product);
  return { id, body, found: 1, operation: "create_product" };
}

// [translate] .get_product
export function translateGetProduct(req: TranslateRequest): TranslateResponse {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "get") return notFound();
  return { id: match[1], body: new Uint8Array(672), found: 1, operation: "get_product" };
}

// [translate] .list_products
export function translateListProducts(req: TranslateRequest): TranslateResponse {
  if (req.method !== "get" || req.path !== "/products") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "list_products" };
}

// [translate] .update_product
export function translateUpdateProduct(req: TranslateRequest): TranslateResponse {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "put") return notFound();
  const parsed = JSON.parse(req.body || "{}");
  const product = makeProduct(parsed, match[1]);
  const body = new Uint8Array(672);
  writeProduct(body, 0, product);
  return { id: match[1], body, found: 1, operation: "update_product" };
}

// [translate] .delete_product
export function translateDeleteProduct(req: TranslateRequest): TranslateResponse {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "delete") return notFound();
  return { id: match[1], body: new Uint8Array(672), found: 1, operation: "delete_product" };
}

// [translate] .get_product_inventory
export function translateGetProductInventory(req: TranslateRequest): TranslateResponse {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})\/inventory$/);
  if (!match || req.method !== "get") return notFound();
  return { id: match[1], body: new Uint8Array(672), found: 1, operation: "get_product_inventory" };
}

// [translate] .search_products
export function translateSearchProducts(req: TranslateRequest): TranslateResponse {
  if (req.method !== "get" || !req.path.startsWith("/products/search")) return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "search_products" };
}

// ---------------------------------------------------------------------------
// Execute
// ---------------------------------------------------------------------------

interface ExecuteResult {
  status: string;
  writes: unknown[];
}

// [execute] .create_product
export function executeCreateProduct(cache: PrefetchCache, body: Uint8Array): ExecuteResult {
  if (cache.product !== null) return { status: "version_conflict", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .get_product
export function executeGetProduct(cache: PrefetchCache): ExecuteResult {
  if (cache.product === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .list_products
export function executeListProducts(cache: PrefetchCache): ExecuteResult {
  return { status: "ok", writes: [] };
}

// [execute] .update_product
export function executeUpdateProduct(cache: PrefetchCache, body: Uint8Array): ExecuteResult {
  if (cache.product === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .delete_product
export function executeDeleteProduct(cache: PrefetchCache): ExecuteResult {
  if (cache.product === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .get_product_inventory
export function executeGetProductInventory(cache: PrefetchCache): ExecuteResult {
  if (cache.product === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .search_products
export function executeSearchProducts(cache: PrefetchCache): ExecuteResult {
  return { status: "ok", writes: [] };
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// [render] .create_product
export function renderCreateProduct(op: string, status: string, result: ExecuteResult): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="product">Created</div>`;
}

// [render] .get_product
export function renderGetProduct(op: string, status: string, result: ExecuteResult, cache?: PrefetchCache): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="product">Product detail</div>`;
}

// [render] .list_products
export function renderListProducts(op: string, status: string, result: ExecuteResult): string {
  return `<div class="products">Product list</div>`;
}

// [render] .update_product
export function renderUpdateProduct(op: string, status: string, result: ExecuteResult): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="product">Updated</div>`;
}

// [render] .delete_product
export function renderDeleteProduct(op: string, status: string, result: ExecuteResult): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="product">Deleted</div>`;
}

// [render] .get_product_inventory
export function renderGetProductInventory(op: string, status: string, result: ExecuteResult): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="inventory">Inventory</div>`;
}

// [render] .search_products
export function renderSearchProducts(op: string, status: string, result: ExecuteResult): string {
  return `<div class="search-results">Search results</div>`;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function notFound(): TranslateResponse {
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 0, operation: "root" };
}

function makeProduct(parsed: Record<string, unknown>, id: string): Product {
  return {
    id,
    name: String(parsed.name || ""),
    description: String(parsed.description || ""),
    price_cents: Number(parsed.price_cents || 0),
    inventory: Number(parsed.inventory || 0),
    version: Number(parsed.version || 1),
    flags: { active: true },
  };
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
