// Product handlers — translate, execute, render.

import type {
  TranslateRequest,
  PrefetchCache,
  Product,
} from "../../generated/types.generated.ts";

// TranslateResult — returned by translate handlers.
// The dispatch serializes the body automatically.
interface TranslateResult {
  operation: string;
  id: string;
  body?: Record<string, unknown> | null;
}

// ---------------------------------------------------------------------------
// Translate
// ---------------------------------------------------------------------------

// [translate] .create_product
export function translateCreateProduct(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "post" || req.path !== "/products") return null;
  const parsed = JSON.parse(req.body || "{}");
  const id = parsed.id || "0".repeat(32);
  return { operation: "create_product", id, body: makeProduct(parsed, id) };
}

// [translate] .get_product
export function translateGetProduct(req: TranslateRequest): TranslateResult | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "get") return null;
  return { operation: "get_product", id: match[1] };
}

// [translate] .list_products
export function translateListProducts(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "get" || req.path !== "/products") return null;
  return { operation: "list_products", id: "0".repeat(32) };
}

// [translate] .update_product
export function translateUpdateProduct(req: TranslateRequest): TranslateResult | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "put") return null;
  const parsed = JSON.parse(req.body || "{}");
  return { operation: "update_product", id: match[1], body: makeProduct(parsed, match[1]) };
}

// [translate] .delete_product
export function translateDeleteProduct(req: TranslateRequest): TranslateResult | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})$/);
  if (!match || req.method !== "delete") return null;
  return { operation: "delete_product", id: match[1] };
}

// [translate] .get_product_inventory
export function translateGetProductInventory(req: TranslateRequest): TranslateResult | null {
  const match = req.path.match(/^\/products\/([a-f0-9]{32})\/inventory$/);
  if (!match || req.method !== "get") return null;
  return { operation: "get_product_inventory", id: match[1] };
}

// [translate] .search_products
export function translateSearchProducts(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "get" || !req.path.startsWith("/products/search")) return null;
  return { operation: "search_products", id: "0".repeat(32) };
}

// ---------------------------------------------------------------------------
// Execute
// ---------------------------------------------------------------------------

interface ExecuteResult {
  status: string;
  writes: unknown[];
}

// [execute] .create_product
export function executeCreateProduct(cache: PrefetchCache, body: Product): ExecuteResult {
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
export function executeUpdateProduct(cache: PrefetchCache, body: Product): ExecuteResult {
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
export function renderCreateProduct(status: string, cache: PrefetchCache): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="product">Created</div>`;
}

// [render] .get_product
export function renderGetProduct(status: string, cache: PrefetchCache): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  if (cache.product) return `<div class="product"><h1>${escapeHtml(cache.product.name)}</h1></div>`;
  return `<div class="error">not_found</div>`;
}

// [render] .list_products
export function renderListProducts(status: string, cache: PrefetchCache): string {
  const items = cache.product_list.items;
  return `<div class="products">${items.map(p => `<div>${escapeHtml(p.name)}</div>`).join("")}</div>`;
}

// [render] .update_product
export function renderUpdateProduct(status: string, cache: PrefetchCache): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="product">Updated</div>`;
}

// [render] .delete_product
export function renderDeleteProduct(status: string, cache: PrefetchCache): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  return `<div class="product">Deleted</div>`;
}

// [render] .get_product_inventory
export function renderGetProductInventory(status: string, cache: PrefetchCache): string {
  if (status !== "ok") return `<div class="error">${escapeHtml(status)}</div>`;
  if (cache.product) return `<div class="inventory">${cache.product.inventory}</div>`;
  return `<div class="error">not_found</div>`;
}

// [render] .search_products
export function renderSearchProducts(status: string, cache: PrefetchCache): string {
  return `<div class="search-results">Search results</div>`;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
