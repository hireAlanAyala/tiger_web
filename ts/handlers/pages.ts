// Page and auth handlers — translate, execute, render.

import type { TranslateRequest, PrefetchCache } from "../../generated/types.generated.ts";

interface TranslateResult { operation: string; id: string; body?: Record<string, unknown> | null; }
interface ExecuteResult { status: string; writes: unknown[]; }

// [translate] .page_load_dashboard
export function translatePageLoadDashboard(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "get" || req.path !== "/") return null;
  return { operation: "page_load_dashboard", id: "0".repeat(32) };
}

// [translate] .page_load_login
export function translatePageLoadLogin(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "get" || req.path !== "/login") return null;
  return { operation: "page_load_login", id: "0".repeat(32) };
}

// [translate] .request_login_code
export function translateRequestLoginCode(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "post" || req.path !== "/login/request") return null;
  return { operation: "request_login_code", id: "0".repeat(32) };
}

// [translate] .verify_login_code
export function translateVerifyLoginCode(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "post" || req.path !== "/login/verify") return null;
  return { operation: "verify_login_code", id: "0".repeat(32) };
}

// [translate] .logout
export function translateLogout(req: TranslateRequest): TranslateResult | null {
  if (req.method !== "post" || req.path !== "/logout") return null;
  return { operation: "logout", id: "0".repeat(32) };
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
export function renderPageLoadDashboard(status: string, cache: PrefetchCache): string { return "<div>Dashboard</div>"; }

// [render] .page_load_login
export function renderPageLoadLogin(status: string): string { return "<div>Login</div>"; }

// [render] .request_login_code
export function renderRequestLoginCode(status: string): string { return status === "ok" ? "<div>Code sent</div>" : "<div>Error</div>"; }

// [render] .verify_login_code
export function renderVerifyLoginCode(status: string): string { return status === "ok" ? "<div>Verified</div>" : "<div>Error</div>"; }

// [render] .logout
export function renderLogout(status: string): string { return "<div>Logged out</div>"; }
