// Focus SDK — types and utilities for TypeScript handlers.
//
// Handlers import from "focus" which resolves here.
// Four handler phases: route → prefetch → handle → render.
// Prefetch is declarative SQL. Handle queues writes via db.execute().

// --- Handler API types ---

/** Route request — the parsed HTTP request passed to the route function. */
export interface RouteRequest {
  method: string;
  path: string;
  body: string;
  params: Record<string, string>;
}

/** Route result — what the route function returns. null = no match.
 *  Operation is inferred from the annotation — don't repeat it here.
 *  id is optional — reads without an entity ID omit it (defaults to zero). */
export interface RouteResult {
  id?: string;
  body?: Record<string, unknown>;
}

/** Prefetch message — identifies the request for prefetch SQL declarations. */
export interface PrefetchMessage {
  operation: string;
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
 *  db.query() returns a single row or null.
 *  db.queryAll() returns an array of rows. */
export interface PrefetchDb {
  /** Single row or null. */
  query(sql: string, ...params: unknown[]): PrefetchQuery | Promise<any>;
  /** Array of rows. */
  queryAll(sql: string, ...params: unknown[]): PrefetchQuery | Promise<any>;
}

/** Handle context — prefetched data + request body for the handle phase. */
export interface HandleContext<P = any> {
  operation: string;
  id: string;
  prefetched: P;
  body: Record<string, any>;
  /** True when a worker dispatch failed or timed out. */
  worker_failed?: boolean;
}

/** Write-only database — handle calls db.execute() to queue SQL writes. */
export interface WriteDb {
  execute(sql: string, ...params: unknown[]): void;
}

/** Render context — status + prefetched data for producing HTML. */
export interface RenderContext<P = any> {
  operation: string;
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
