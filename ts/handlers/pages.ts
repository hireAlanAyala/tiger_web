// Page and auth handlers — translate, execute, render.

import type { TranslateRequest, TranslateResponse, PrefetchCache } from "../../generated/types.generated.ts";

interface ExecuteResult { status: string; writes: unknown[]; }
function notFound(): TranslateResponse { return { id: "0".repeat(32), body: new Uint8Array(672), found: 0, operation: "root" }; }

// [translate] .page_load_dashboard
export function translatePageLoadDashboard(req: TranslateRequest): TranslateResponse {
  if (req.method !== "get" || req.path !== "/") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "page_load_dashboard" };
}

// [translate] .page_load_login
export function translatePageLoadLogin(req: TranslateRequest): TranslateResponse {
  if (req.method !== "get" || req.path !== "/login") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "page_load_login" };
}

// [translate] .request_login_code
export function translateRequestLoginCode(req: TranslateRequest): TranslateResponse {
  if (req.method !== "post" || req.path !== "/login/request") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "request_login_code" };
}

// [translate] .verify_login_code
export function translateVerifyLoginCode(req: TranslateRequest): TranslateResponse {
  if (req.method !== "post" || req.path !== "/login/verify") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "verify_login_code" };
}

// [translate] .logout
export function translateLogout(req: TranslateRequest): TranslateResponse {
  if (req.method !== "post" || req.path !== "/logout") return notFound();
  return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "logout" };
}

// [execute] .page_load_dashboard
export function executePageLoadDashboard(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .page_load_login
export function executePageLoadLogin(): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .request_login_code
export function executeRequestLoginCode(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .verify_login_code
export function executeVerifyLoginCode(cache: PrefetchCache): ExecuteResult { return { status: "ok", writes: [] }; }

// [execute] .logout
export function executeLogout(): ExecuteResult { return { status: "ok", writes: [] }; }

// [render] .page_load_dashboard
export function renderPageLoadDashboard(): string { return "<div>Dashboard</div>"; }

// [render] .page_load_login
export function renderPageLoadLogin(): string { return "<div>Login</div>"; }

// [render] .request_login_code
export function renderRequestLoginCode(_op: string, status: string): string { return status === "ok" ? "<div>Code sent</div>" : "<div>Error</div>"; }

// [render] .verify_login_code
export function renderVerifyLoginCode(_op: string, status: string): string { return status === "ok" ? "<div>Verified</div>" : "<div>Error</div>"; }

// [render] .logout
export function renderLogout(): string { return "<div>Logged out</div>"; }
