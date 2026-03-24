// Page and auth handlers — each operation groups route → handle → render.

import type { Request, Route, Response, Context } from "tiger-web";

// ========================== page_load_dashboard ==========================

// [route] .page_load_dashboard
// match GET /
export function routePageLoadDashboard(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/") return null;
  return { operation: "page_load_dashboard", id: "0".repeat(32) };
}

// [handle] .page_load_dashboard
export function handlePageLoadDashboard(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .page_load_dashboard
export function renderPageLoadDashboard(status: string, ctx: Context): string {
  return "<div>Dashboard</div>";
}

// ========================== page_load_login ==========================

// [route] .page_load_login
// match GET /login
export function routePageLoadLogin(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/login") return null;
  return { operation: "page_load_login", id: "0".repeat(32) };
}

// [handle] .page_load_login
export function handlePageLoadLogin(): Response {
  return { status: "ok", writes: [] };
}

// [render] .page_load_login
export function renderPageLoadLogin(status: string): string {
  return "<div>Login</div>";
}

// ========================== request_login_code ==========================

// [route] .request_login_code
// match POST /login/request
export function routeRequestLoginCode(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/login/request") return null;
  return { operation: "request_login_code", id: "0".repeat(32) };
}

// [handle] .request_login_code
export function handleRequestLoginCode(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .request_login_code
export function renderRequestLoginCode(status: string): string {
  return status === "ok" ? "<div>Code sent</div>" : "<div>Error</div>";
}

// ========================== verify_login_code ==========================

// [route] .verify_login_code
// match POST /login/verify
export function routeVerifyLoginCode(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/login/verify") return null;
  return { operation: "verify_login_code", id: "0".repeat(32) };
}

// [handle] .verify_login_code
export function handleVerifyLoginCode(ctx: Context): Response {
  return { status: "ok", writes: [] };
}

// [render] .verify_login_code
export function renderVerifyLoginCode(status: string): string {
  return status === "ok" ? "<div>Verified</div>" : "<div>Error</div>";
}

// ========================== logout ==========================

// [route] .logout
// match POST /logout
export function routeLogout(req: Request): Route | null {
  if (req.method !== "post" || req.path !== "/logout") return null;
  return { operation: "logout", id: "0".repeat(32) };
}

// [handle] .logout
export function handleLogout(): Response {
  return { status: "ok", writes: [] };
}

// [render] .logout
export function renderLogout(status: string): string {
  return "<div>Logged out</div>";
}
