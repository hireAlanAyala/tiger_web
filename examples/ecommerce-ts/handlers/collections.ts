// Collection handlers — each operation groups route → handle → render.

import type { Request, Route, Response, Context, ProductCollection } from "tiger-web";
import { assert } from "tiger-web";

// ========================== create_collection ==========================

// [route] .create_collection
export function routeCreateCollection(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/collections") return null;
  const parsed = JSON.parse(req.body || "{}");
  const name = String(parsed.name || "");
  if (name.length === 0) return null;
  return { operation: "create_collection", id: "0".repeat(32) };
}

// [handle] .create_collection
export function handleCreateCollection(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .create_collection
export function renderCreateCollection(status: string): string {
  return status === "ok" ? "<div>Created</div>" : `<div>${esc(status)}</div>`;
}

// ========================== get_collection ==========================

// [route] .get_collection
export function routeGetCollection(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return null;
  return { operation: "get_collection", id: m[1] };
}

// [handle] .get_collection
export function handleGetCollection(ctx: Context): Response {
  if (ctx.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .get_collection
export function renderGetCollection(status: string, ctx: Context): string {
  if (status !== "ok") return `<div>${esc(status)}</div>`;
  const col = assertCollection(ctx);
  return `<div>Collection: ${esc(col.name)}</div>`;
}

// ========================== list_collections ==========================

// [route] .list_collections
export function routeListCollections(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/collections") return null;
  return { operation: "list_collections", id: "0".repeat(32) };
}

// [handle] .list_collections
export function handleListCollections(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .list_collections
export function renderListCollections(status: string, ctx: Context): string {
  return "<div>Collections</div>";
}

// ========================== delete_collection ==========================

// [route] .delete_collection
export function routeDeleteCollection(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return null;
  return { operation: "delete_collection", id: m[1] };
}

// [handle] .delete_collection
export function handleDeleteCollection(ctx: Context): Response {
  if (ctx.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .delete_collection
export function renderDeleteCollection(status: string): string {
  return status === "ok" ? "<div>Deleted</div>" : `<div>${esc(status)}</div>`;
}

// ========================== add_collection_member ==========================

// [route] .add_collection_member
export function routeAddCollectionMember(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members$/);
  if (!m || req.method !== "post") return null;
  return { operation: "add_collection_member", id: m[1] };
}

// [handle] .add_collection_member
export function handleAddCollectionMember(ctx: Context): Response {
  if (ctx.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .add_collection_member
export function renderAddCollectionMember(status: string): string {
  return status === "ok" ? "<div>Added</div>" : `<div>${esc(status)}</div>`;
}

// ========================== remove_collection_member ==========================

// [route] .remove_collection_member
export function routeRemoveCollectionMember(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return null;
  return { operation: "remove_collection_member", id: m[1] };
}

// [handle] .remove_collection_member
export function handleRemoveCollectionMember(ctx: Context): Response {
  if (ctx.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [render] .remove_collection_member
export function renderRemoveCollectionMember(status: string): string {
  return status === "ok" ? "<div>Removed</div>" : `<div>${esc(status)}</div>`;
}

// ========================== assertions ==========================

function assertCollection(ctx: Context): ProductCollection {
  assert(ctx.collection !== null, "render: collection is null after ok status");
  return ctx.collection;
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
