// Order handlers — translate, execute, render.

import type { TranslateRequest, PrefetchCache } from "../../generated/types.generated.ts";

interface TranslateResult { operation: string; id: string; body?: Record<string, unknown> | null; }
interface ExecuteResult { status: string; writes: unknown[]; }
function escapeHtml(s: string): string { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

// [translate] .create_order
export function translateCreateOrder(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "post" || req.path !== "/orders") return null;
  return { operation: "create_order", id: "0".repeat(32) };
}

// [translate] .get_order
export function translateGetOrder(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return null;
  return { operation: "get_order", id: m[1] };
}

// [translate] .list_orders
export function translateListOrders(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "get" || req.path !== "/orders") return null;
  return { operation: "list_orders", id: "0".repeat(32) };
}

// [translate] .complete_order
export function translateCompleteOrder(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/complete$/);
  if (!m || req.method !== "post") return null;
  return { operation: "complete_order", id: m[1] };
}

// [translate] .cancel_order
export function translateCancelOrder(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/cancel$/);
  if (!m || req.method !== "post") return null;
  return { operation: "cancel_order", id: m[1] };
}

// [translate] .transfer_inventory
export function translateTransferInventory(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/products\/([a-f0-9]{32})\/transfer-inventory\/([a-f0-9]{32})$/);
  if (!m || req.method !== "post") return null;
  return { operation: "transfer_inventory", id: m[1] };
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
export function renderCreateOrder(status: string): string { return status === "ok" ? "<div>Order created</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .get_order
export function renderGetOrder(status: string, cache: PrefetchCache): string { return status === "ok" ? "<div>Order detail</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .list_orders
export function renderListOrders(status: string, cache: PrefetchCache): string { return "<div>Orders</div>"; }

// [render] .complete_order
export function renderCompleteOrder(status: string): string { return status === "ok" ? "<div>Completed</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .cancel_order
export function renderCancelOrder(status: string): string { return status === "ok" ? "<div>Cancelled</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .transfer_inventory
export function renderTransferInventory(status: string): string { return status === "ok" ? "<div>Transferred</div>" : `<div>${escapeHtml(status)}</div>`; }
