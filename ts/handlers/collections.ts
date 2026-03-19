// Collection handlers — translate, execute, render.

import type { TranslateRequest, PrefetchCache } from "../../generated/types.generated.ts";

interface TranslateResult { operation: string; id: string; body?: Record<string, unknown> | null; }
interface ExecuteResult { status: string; writes: unknown[]; }
function escapeHtml(s: string): string { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

// [translate] .create_collection
export function translateCreateCollection(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "post" || req.path !== "/collections") return null;
  return { operation: "create_collection", id: "0".repeat(32) };
}

// [translate] .get_collection
export function translateGetCollection(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "get") return null;
  return { operation: "get_collection", id: m[1] };
}

// [translate] .list_collections
export function translateListCollections(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "get" || req.path !== "/collections") return null;
  return { operation: "list_collections", id: "0".repeat(32) };
}

// [translate] .delete_collection
export function translateDeleteCollection(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return null;
  return { operation: "delete_collection", id: m[1] };
}

// [translate] .add_collection_member
export function translateAddCollectionMember(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members$/);
  if (!m || req.method !== "post") return null;
  return { operation: "add_collection_member", id: m[1] };
}

// [translate] .remove_collection_member
export function translateRemoveCollectionMember(req: TranslateRequest): TranslateResult | null {
  const m = req.path.match(/^\/collections\/([a-f0-9]{32})\/members\/([a-f0-9]{32})$/);
  if (!m || req.method !== "delete") return null;
  return { operation: "remove_collection_member", id: m[1] };
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
export function renderCreateCollection(status: string): string { return status === "ok" ? "<div>Created</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .get_collection
export function renderGetCollection(status: string, cache: PrefetchCache): string { return status === "ok" ? "<div>Collection</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .list_collections
export function renderListCollections(status: string, cache: PrefetchCache): string { return "<div>Collections</div>"; }

// [render] .delete_collection
export function renderDeleteCollection(status: string): string { return status === "ok" ? "<div>Deleted</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .add_collection_member
export function renderAddCollectionMember(status: string): string { return status === "ok" ? "<div>Added</div>" : `<div>${escapeHtml(status)}</div>`; }

// [render] .remove_collection_member
export function renderRemoveCollectionMember(status: string): string { return status === "ok" ? "<div>Removed</div>" : `<div>${escapeHtml(status)}</div>`; }
