// Focus — public API for TypeScript handlers.
//
// Handlers import types and utilities from "focus":
//   import type { RouteRequest, HandleContext, WriteDb } from "focus";
//   import { esc, price } from "focus";

export type {
  RouteRequest,
  RouteResult,
  PrefetchMessage,
  PrefetchQuery,
  PrefetchDb,
  HandleContext,
  WriteDb,
  RenderContext,
} from "./types.js";

export {
  assert,
  esc,
  unreachable,
  price,
  shortId,
} from "./types.js";

export { matchRoute } from "./routing.js";
