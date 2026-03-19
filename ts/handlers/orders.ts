// Order handlers — translate, execute, render.

import type { TranslateRequest, TranslateResponse, PrefetchCache } from "../../generated/types.generated.ts";

interface ExecuteResult { status: string; writes: unknown[]; }
function notFound(): TranslateResponse { return { id: "0".repeat(32), body: new Uint8Array(672), found: 0, operation: "root" }; }
function escapeHtml(s: string): string { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

// [translate] .create_order
export function translateCreateOrder(req: TranslateRequest): TranslateResponse {
  if (req.method !== "post" || req.path !== "/orders") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "create_order" };
}

// [translate] .get_order
export function translateGetOrder(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "get_order" };
}

// [translate] .list_orders
export function translateListOrders(req: TranslateRequest): TranslateResponse {
  if (req.method !== "get" || req.path !== "/orders") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "list_orders" };
}

// [translate] .complete_order
export function translateCompleteOrder(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/complete$/);
  if (!m || req.method !== "post") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "complete_order" };
}

// [translate] .cancel_order
export function translateCancelOrder(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/cancel$/);
  if (!m || req.method !== "post") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "cancel_order" };
}

// [translate] .transfer_inventory
export function translateTransferInventory(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/products\/([a-f0-9]{32})\/transfer-inventory\/([a-f0-9]{32})$/);
  if (!m || req.method !== "post") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "transfer_inventory" };
}

// [execute] .create_order
export function executeCreateOrder(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .get_order
export function executeGetOrder(cache: PrefetchCache): ExecuteResult {
  if (cache.order === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .list_orders
export function executeListOrders(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .complete_order
export function executeCompleteOrder(cache: PrefetchCache): ExecuteResult {
  if (cache.order === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .cancel_order
export function executeCancelOrder(cache: PrefetchCache): ExecuteResult {
  if (cache.order === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .transfer_inventory
export function executeTransferInventory(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [render] .create_order
export function renderCreateOrder(_op: string, status: string): string { return status === "ok" ? "<div>Order created</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .get_order
export function renderGetOrder(_op: string, status: string): string { return status === "ok" ? "<div>Order detail</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .list_orders
export function renderListOrders(): string { return "<div>Orders</div>"; }

// [render] .complete_order
export function renderCompleteOrder(_op: string, status: string): string { return status === "ok" ? "<div>Completed</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .cancel_order
export function renderCancelOrder(_op: string, status: string): string { return status === "ok" ? "<div>Cancelled</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .transfer_inventory
export function renderTransferInventory(_op: string, status: string): string { return status === "ok" ? "<div>Transferred</div>" : `<div>${escapeHtml(status)}</div>`; }
