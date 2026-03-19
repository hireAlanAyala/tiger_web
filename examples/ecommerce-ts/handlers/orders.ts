// Order and inventory handlers — each operation groups route → handle → render.

import type { Request, Route, Response, Context, OrderResult } from "tiger-web";
import { assert } from "tiger-web";

// ========================== create_order ==========================

// [route] .create_order
export function routeCreateOrder(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/orders") return null;
  return { operation: "create_order", id: "0".repeat(32) };
}

// [handle] .create_order
export function handleCreateOrder(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .create_order
export function renderCreateOrder(status: string): string {
  return status === "ok" ? "<div>Order created</div>" : `<div>${esc(status)}</div>`;
}

// ========================== get_order ==========================

// [route] .get_order
export function routeGetOrder(req: Request): Route | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return null;
  return { operation: "get_order", id: m[1] };
}

// [handle] .get_order
export function handleGetOrder(ctx: Context): Response {
  if (ctx.order === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .get_order
export function renderGetOrder(status: string, ctx: Context): string {
  if (status !== "ok") return `<div>${esc(status)}</div>`;
  const order = assertOrder(ctx);
  return `<div>Order ${esc(order.id)} — ${esc(order.status)}</div>`;
}

// ========================== list_orders ==========================

// [route] .list_orders
export function routeListOrders(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/orders") return null;
  return { operation: "list_orders", id: "0".repeat(32) };
}

// [handle] .list_orders
export function handleListOrders(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .list_orders
export function renderListOrders(status: string, ctx: Context): string {
  return "<div>Orders</div>";
}

// ========================== complete_order ==========================

// [route] .complete_order
export function routeCompleteOrder(req: Request): Route | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/complete$/);
  if (!m || req.method !== "post") return null;
  return { operation: "complete_order", id: m[1] };
}

// [handle] .complete_order
export function handleCompleteOrder(ctx: Context): Response {
  if (ctx.order === null) return { status: "not_found", writes: [] };
  // Positive + negative: only pending orders can be completed.
  if (ctx.order.status !== "pending") return { status: "version_conflict", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .complete_order
export function renderCompleteOrder(status: string): string {
  return status === "ok" ? "<div>Completed</div>" : `<div>${esc(status)}</div>`;
}

// ========================== cancel_order ==========================

// [route] .cancel_order
export function routeCancelOrder(req: Request): Route | null {
  const m = req.path.match(/^\/orders\/([a-f0-9]{32})\/cancel$/);
  if (!m || req.method !== "post") return null;
  return { operation: "cancel_order", id: m[1] };
}

// [handle] .cancel_order
export function handleCancelOrder(ctx: Context): Response {
  if (ctx.order === null) return { status: "not_found", writes: [] };
  // Can't cancel a completed or already-cancelled order.
  if (ctx.order.status !== "pending") return { status: "version_conflict", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .cancel_order
export function renderCancelOrder(status: string): string {
  return status === "ok" ? "<div>Cancelled</div>" : `<div>${esc(status)}</div>`;
}

// ========================== transfer_inventory ==========================

// [route] .transfer_inventory
export function routeTransferInventory(req: Request): Route | null {
  const m = req.path.match(/^\/products\/([a-f0-9]{32})\/transfer-inventory\/([a-f0-9]{32})$/);
  if (!m || req.method !== "post") return null;
  return { operation: "transfer_inventory", id: m[1] };
}

// [handle] .transfer_inventory
export function handleTransferInventory(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .transfer_inventory
export function renderTransferInventory(status: string): string {
  return status === "ok" ? "<div>Transferred</div>" : `<div>${esc(status)}</div>`;
}

// ========================== assertions ==========================

function assertOrder(ctx: Context): OrderResult {
  assert(ctx.order !== null, "render: order is null after ok status");
  return ctx.order;
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
