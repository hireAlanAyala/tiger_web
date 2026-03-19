// Collection handlers — translate, execute, render.

import type { TranslateRequest, TranslateResponse, PrefetchCache } from "../../generated/types.generated.ts";

interface ExecuteResult { status: string; writes: unknown[]; }
function notFound(): TranslateResponse { return { id: "0".repeat(32), body: new Uint8Array(672), found: 0, operation: "root" }; }
function escapeHtml(s: string): string { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

// [translate] .create_collection
export function translateCreateCollection(req: TranslateRequest): TranslateResponse {
  if (req.method !== "post" || req.path !== "/collections") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "create_collection" };
}

// [translate] .get_collection
export function translateGetCollection(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "get_collection" };
}

// [translate] .list_collections
export function translateListCollections(req: TranslateRequest): TranslateResponse {
  if (req.method !== "get" || req.path !== "/collections") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "list_collections" };
}

// [translate] .delete_collection
export function translateDeleteCollection(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "delete_collection" };
}

// [translate] .add_collection_member
export function translateAddCollectionMember(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members$/);
  if (!m || req.method !== "post") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "add_collection_member" };
}

// [translate] .remove_collection_member
export function translateRemoveCollectionMember(req: TranslateRequest): TranslateResponse {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return notFound();
  return { id: m[1], body: new Uint8Array(672), found: 1, operation: "remove_collection_member" };
}

// [execute] .create_collection
export function executeCreateCollection(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .get_collection
export function executeGetCollection(cache: PrefetchCache): ExecuteResult {
  if (cache.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .list_collections
export function executeListCollections(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .delete_collection
export function executeDeleteCollection(cache: PrefetchCache): ExecuteResult {
  if (cache.collection === null) return { status: "not_found", writes: [] };
  return { status: "ok", writes: [] };
}

// [execute] .add_collection_member
export function executeAddCollectionMember(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .remove_collection_member
export function executeRemoveCollectionMember(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [render] .create_collection
export function renderCreateCollection(_op: string, status: string): string { return status === "ok" ? "<div>Created</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .get_collection
export function renderGetCollection(_op: string, status: string): string { return status === "ok" ? "<div>Collection</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .list_collections
export function renderListCollections(): string { return "<div>Collections</div>"; }

// [render] .delete_collection
export function renderDeleteCollection(_op: string, status: string): string { return status === "ok" ? "<div>Deleted</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .add_collection_member
export function renderAddCollectionMember(_op: string, status: string): string { return status === "ok" ? "<div>Added</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .remove_collection_member
export function renderRemoveCollectionMember(_op: string, status: string): string { return status === "ok" ? "<div>Removed</div>" : `<div>${escapeHtml(status)}</div>`; }
