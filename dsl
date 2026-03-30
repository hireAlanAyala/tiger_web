
// [route] .page_load_dashboard
export function routePageLoadDashboard(req: Request): Route | null {
  if (req.method !== "get" || req.path !== "/") return null;
  return { operation: "page_load_dashboard", id: "0".repeat(32) };
}

interface ExecuteResult {
  status: string;
  writes: unknown[];
}

// [execute] .create_product
export function executeCreateProduct(cache: PrefetchCache, body: Uint8Array): ExecuteResult {
  if (cache.product !== null) return { status: "version_conflict", writes: [] };
  return { status: "ok", writes: [] };
}


// [render] .list_collections
export function renderListCollections(status: string, ctx: Context): string {
  return "<div>Collections</div>";
}
