// Order handlers — translate, execute, render.

import type { Request, Route, Response, Context } from "../../generated/types.generated.ts";
function escapeHtml(s: string): string { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

// [route] .create_order
export function translateCreateOrder(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/orders") return null;
  return { operation: "create_order", id: "0".repeat(32) };
}

// [route] .get_order
export function translateGetOrder(req: Request): Route | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return null;
  return { operation: "get_order", id: m[1] };
}

// [route] .list_orders
export function translateListOrders(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/orders") return null;
  return { operation: "list_orders", id: "0".repeat(32) };
}

// [route] .complete_order
export function translateCompleteOrder(req: Request): Route | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/complete$/);
  if (!m || req.method !== "post") return null;
  return { operation: "complete_order", id: m[1] };
}

// [route] .cancel_order
export function translateCancelOrder(req: Request): Route | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/cancel$/);
  if (!m || req.method !== "post") return null;
  return { operation: "cancel_order", id: m[1] };
}

// [route] .transfer_inventory
export function translateTransferInventory(req: Request): Route | null {
  const m = req.path.match(/^\/products\/([a-f0-9]{32})\/transfer-inventory\/([a-f0-9]{32})$/);
  if (!m || req.method !== "post") return null;
  return { operation: "transfer_inventory", id: m[1] };
}

// [handle] .create_order
export function executeCreateOrder(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .get_order
export function executeGetOrder(cache: Context): Response {
  if (cache.order === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [handle] .list_orders
export function executeListOrders(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .complete_order
export function executeCompleteOrder(cache: Context): Response {
  if (cache.order === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [handle] .cancel_order
export function executeCancelOrder(cache: Context): Response {
  if (cache.order === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [handle] .transfer_inventory
export function executeTransferInventory(cache: Context): Response { return { status: "ok", writes: [] }; }

// [render] .create_order
export function renderCreateOrder(status: string): string { return status === "ok" ? "<div>Order created</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .get_order
export function renderGetOrder(status: string, cache: Context): string { return status === "ok" ? "<div>Order detail</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .list_orders
export function renderListOrders(status: string, cache: Context): string { return "<div>Orders</div>"; }

// [render] .complete_order
export function renderCompleteOrder(status: string): string { return status === "ok" ? "<div>Completed</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .cancel_order
export function renderCancelOrder(status: string): string { return status === "ok" ? "<div>Cancelled</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .transfer_inventory
export function renderTransferInventory(status: string): string { return status === "ok" ? "<div>Transferred</div>" : `<div>${escapeHtml(status)}</div>`; }
