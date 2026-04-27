// Route matching — shared across all sidecar language implementations.
// Port of framework/parse.zig match_route(). Verified by cross-language
// test vectors (route_match_vectors.json).
//
// The matching algorithm: split pattern and path by /, match literal
// segments exactly, extract :param values. Reject if segment counts
// differ, if a literal doesn't match, or if a param segment is empty.
// Query strings are stripped before matching.

/**
 * Match a request path against a route pattern, extracting :param values.
 * Returns params object or null if no match.
 *
 * Examples:
 *   matchRoute("/products/abc123", "/products/:id")  → { id: "abc123" }
 *   matchRoute("/orders", "/products")               → null
 *   matchRoute("/products?q=foo", "/products")       → {}
 */
export function matchRoute(
  rawPath: string,
  pattern: string,
): Record<string, string> | null {
  if (rawPath.length === 0 || rawPath[0] !== "/") return null;

  // Strip query string before matching — framework concern, not handler concern.
  // Native Zig pipeline strips query string in http.zig before match_route.
  const qmark = rawPath.indexOf("?");
  const path = qmark >= 0 ? rawPath.slice(0, qmark) : rawPath;

  // Root pattern matches root path only.
  if (pattern === "/") {
    return path === "/" ? {} : null;
  }

  const patSegs = pattern.slice(1).split("/");
  const pathSegs = path.slice(1).split("/");

  if (patSegs.length !== pathSegs.length) return null;

  const params: Record<string, string> = {};
  for (let i = 0; i < patSegs.length; i++) {
    const pat = patSegs[i];
    const val = pathSegs[i];
    if (pat.startsWith(":")) {
      if (val.length === 0) return null;
      params[pat.slice(1)] = val;
    } else {
      if (pat !== val) return null;
    }
  }
  return params;
}
