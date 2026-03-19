// Collection handlers — translate, execute, render.

import type { Request, Route, Response, Context } from "../../generated/types.generated.ts";
function escapeHtml(s: string): string { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

// [route] .create_collection
export function translateCreateCollection(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/collections") return null;
  return { operation: "create_collection", id: "0".repeat(32) };
}

// [route] .get_collection
export function translateGetCollection(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return null;
  return { operation: "get_collection", id: m[1] };
}

// [route] .list_collections
export function translateListCollections(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/collections") return null;
  return { operation: "list_collections", id: "0".repeat(32) };
}

// [route] .delete_collection
export function translateDeleteCollection(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return null;
  return { operation: "delete_collection", id: m[1] };
}

// [route] .add_collection_member
export function translateAddCollectionMember(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members$/);
  if (!m || req.method !== "post") return null;
  return { operation: "add_collection_member", id: m[1] };
}

// [route] .remove_collection_member
export function translateRemoveCollectionMember(req: Request): Route | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return null;
  return { operation: "remove_collection_member", id: m[1] };
}

// [handle] .create_collection
export function executeCreateCollection(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .get_collection
export function executeGetCollection(cache: Context): Response {
  if (cache.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [handle] .list_collections
export function executeListCollections(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .delete_collection
export function executeDeleteCollection(cache: Context): Response {
  if (cache.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [handle] .add_collection_member
export function executeAddCollectionMember(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .remove_collection_member
export function executeRemoveCollectionMember(cache: Context): Response { return { status: "ok", writes: [] }; }

// [render] .create_collection
export function renderCreateCollection(status: string): string { return status === "ok" ? "<div>Created</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .get_collection
export function renderGetCollection(status: string, cache: Context): string { return status === "ok" ? "<div>Collection</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .list_collections
export function renderListCollections(status: string, cache: Context): string { return "<div>Collections</div>"; }

// [render] .delete_collection
export function renderDeleteCollection(status: string): string { return status === "ok" ? "<div>Deleted</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .add_collection_member
export function renderAddCollectionMember(status: string): string { return status === "ok" ? "<div>Added</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .remove_collection_member
export function renderRemoveCollectionMember(status: string): string { return status === "ok" ? "<div>Removed</div>" : `<div>${escapeHtml(status)}</div>`; }
