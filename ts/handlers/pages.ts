// Page and auth handlers — translate, execute, render.

import type { Request, Route, Response, Context } from "../../generated/types.generated.ts";

// [route] .page_load_dashboard
export function translatePageLoadDashboard(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/") return null;
  return { operation: "page_load_dashboard", id: "0".repeat(32) };
}

// [route] .page_load_login
export function translatePageLoadLogin(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/login") return null;
  return { operation: "page_load_login", id: "0".repeat(32) };
}

// [route] .request_login_code
export function translateRequestLoginCode(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/login/request") return null;
  return { operation: "request_login_code", id: "0".repeat(32) };
}

// [route] .verify_login_code
export function translateVerifyLoginCode(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/login/verify") return null;
  return { operation: "verify_login_code", id: "0".repeat(32) };
}

// [route] .logout
export function translateLogout(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/logout") return null;
  return { operation: "logout", id: "0".repeat(32) };
}

// [handle] .page_load_dashboard
export function executePageLoadDashboard(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .page_load_login
export function executePageLoadLogin(): Response { return { status: "ok", writes: [] }; }

// [handle] .request_login_code
export function executeRequestLoginCode(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .verify_login_code
export function executeVerifyLoginCode(cache: Context): Response { return { status: "ok", writes: [] }; }

// [handle] .logout
export function executeLogout(): Response { return { status: "ok", writes: [] }; }

// [render] .page_load_dashboard
export function renderPageLoadDashboard(status: string, cache: Context): string { return "<div>Dashboard</div>"; }

// [render] .page_load_login
export function renderPageLoadLogin(status: string): string { return "<div>Login</div>"; }

// [render] .request_login_code
export function renderRequestLoginCode(status: string): string { return status === "ok" ? "<div>Code sent</div>" : "<div>Error</div>"; }

// [render] .verify_login_code
export function renderVerifyLoginCode(status: string): string { return status === "ok" ? "<div>Verified</div>" : "<div>Error</div>"; }

// [render] .logout
export function renderLogout(status: string): string { return "<div>Logged out</div>"; }
