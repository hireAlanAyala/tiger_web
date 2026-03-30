// Tiger Web SDK — types and utilities for TypeScript handlers.
// Hand-written SDK. Correctness verified by cross-language tests (serde_test.ts).
//
// Tiger Web SDK — types and utilities for TypeScript handlers.
// Handlers import from "tiger-web" which resolves here via tsconfig paths.
//
// New protocol: JSON length-prefixed frames over unix socket.
// Four handler phases: route → prefetch → handle → render.
// Prefetch is declarative SQL. Handle queues writes via db.execute().
// No binary serde. No PrefetchCache. No WriteSlot.

// --- Constants from message.zig ---

export const list_max = 50;
export const dashboard_list_max = 10;
export const order_items_max = 20;
export const product_name_max = 128;
export const product_description_max = 512;
export const collection_name_max = 128;
export const search_query_max = 128;
export const email_max = 128;
export const code_length = 6;
export const payment_ref_max = 64;
export const order_timeout_seconds = 60;

// --- Enums ---

export type Operation =
  | "root"
  | "create_product"
  | "get_product"
  | "list_products"
  | "update_product"
  | "delete_product"
  | "get_product_inventory"
  | "transfer_inventory"
  | "create_order"
  | "get_order"
  | "list_orders"
  | "complete_order"
  | "cancel_order"
  | "search_products"
  | "create_collection"
  | "get_collection"
  | "list_collections"
  | "delete_collection"
  | "add_collection_member"
  | "remove_collection_member"
  | "page_load_dashboard"
  | "page_load_login"
  | "request_login_code"
  | "verify_login_code"
  | "logout"
  ;

export type Status =
  | "ok"
  | "not_found"
  | "storage_error"
  | "insufficient_inventory"
  | "version_conflict"
  | "order_expired"
  | "order_not_pending"
  | "invalid_code"
  | "code_expired"
  ;

export type OrderStatus = "pending" | "confirmed" | "failed" | "cancelled";

// --- Enum value mappings (match message.zig) ---
// Used by the dispatch to convert between string names and u8 wire values.

export const OperationValues: Record<string, number> = {
  root: 0,
  create_product: 1, get_product: 2, list_products: 3,
  update_product: 4, delete_product: 5, get_product_inventory: 6,
  create_collection: 7, get_collection: 8, list_collections: 9,
  delete_collection: 10, add_collection_member: 11, remove_collection_member: 12,
  transfer_inventory: 13, create_order: 14, get_order: 15, list_orders: 16,
  complete_order: 17, cancel_order: 18, search_products: 19,
  page_load_dashboard: 20, request_login_code: 21, verify_login_code: 22,
  logout: 23, page_load_login: 24,
};

export const StatusValues: Record<string, number> = {
  ok: 1, not_found: 2, storage_error: 4,
  insufficient_inventory: 10, version_conflict: 11, order_expired: 12,
  order_not_pending: 13, invalid_code: 14, code_expired: 15,
};

export const StatusNames: Record<number, string> = Object.fromEntries(
  Object.entries(StatusValues).map(([k, v]) => [v, k])
);

export const OperationNames: Record<number, string> = Object.fromEntries(
  Object.entries(OperationValues).map(([k, v]) => [v, k])
);

// --- Handler API types ---

/** Route request — what the framework sends after pre-matching the URL pattern. */
export interface RouteRequest {
  method: string;
  path: string;
  body: string;
  params: Record<string, string>;
}

/** Route result — what the route function returns. null = no match. */
export interface RouteResult {
  operation: Operation;
  id: string;
  body?: Record<string, unknown>;
}

/** Prefetch message — identifies the request for prefetch SQL declarations. */
export interface PrefetchMessage {
  operation: Operation;
  id: string;
  body: Record<string, unknown>;
}

/** Prefetch query — a single SQL query declaration. */
export interface PrefetchQuery {
  sql: string;
  params: unknown[];
  mode: "query" | "queryAll";
}

/** Read-only database for prefetch.
 *  In the CALL/RESULT protocol, db.query() sends a QUERY frame to the
 *  server and returns a Promise that resolves with the row data.
 *  In the legacy 3-RT protocol, returns a declaration object. */
export interface PrefetchDb {
  /** Single row or null. */
  query(sql: string, ...params: unknown[]): PrefetchQuery | Promise<any>;
  /** Array of rows. */
  queryAll(sql: string, ...params: unknown[]): PrefetchQuery | Promise<any>;
}

/** Handle context — prefetched data + request body for the handle phase.
 *  Prefetched fields are `any` — data comes from SQL results over JSON. */
export interface HandleContext<P = any> {
  operation: Operation;
  id: string;
  prefetched: P;
  body: Record<string, any>;
}

/** Write-only database — handle calls db.execute() to queue SQL writes. */
export interface WriteDb {
  execute(sql: string, ...params: unknown[]): void;
}

/** Render context — status + prefetched data for producing HTML.
 *  Prefetched fields are `any` — data comes from SQL results over JSON. */
export interface RenderContext<P = any> {
  operation: Operation;
  id: string;
  status: string;
  prefetched: P;
  body: Record<string, any>;
  is_sse: boolean;
}

// --- Utilities ---

/** Assert a condition. Throws on failure. */
export function assert(condition: unknown, msg: string): asserts condition {
  if (!condition) throw new Error("assertion failed: " + msg);
}

/** HTML-escape a string. Use in render() for user-provided text. */
export function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Exhaustiveness check — call in switch default to get a compile error if a case is missing. */
export function unreachable(x: never): never {
  throw new Error("unreachable: " + x);
}

/** Format cents as a dollar string. */
export function price(cents: number): string {
  return "$" + (cents / 100).toFixed(2);
}

/** Truncate a hex UUID to first 8 chars for display. */
export function shortId(id: string): string {
  return id.slice(0, 8);
}
