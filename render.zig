const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const message = @import("message.zig");
const http = @import("http.zig");

/// Empty dashboard — used for error responses, auth failures, and comptime
/// buffer sizing. Every non-SSE error renders the full page (with token input)
/// so the user has a recovery path.
const empty_dashboard = message.PageLoadDashboardResult{
    .products = .{ .items = undefined, .len = 0 },
    .collections = .{ .items = undefined, .len = 0 },
    .orders = .{ .items = undefined, .len = 0 },
};

// --- Buffer constants ---
// Derived at comptime by running the actual renderers on worst-case input.
// If the HTML changes, the constants update automatically — no manual counting.
// Buffer math uses dashboard_list_max (domain constant), not list_max.

pub const product_card_max = comptime_render_size(message.Product, render_product_card);
pub const collection_card_max = comptime_render_size(message.ProductCollection, render_collection_card);
pub const order_card_max = comptime_render_size(message.OrderSummary, render_order_card);

/// Full page with empty lists — measures the page shell (headers + CSS + scaffold).
pub const page_shell_max = blk: {
    @setEvalBranchQuota(100_000);
    var buf: [64 * 1024]u8 = undefined;
    var w = HtmlWriter{ .buf = &buf, .pos = 0 };
    encode_full_page(&w, &empty_dashboard);
    break :blk w.pos;
};

/// "Showing first N" indicator rendered at dashboard_list_max.
const count_indicator_max = blk: {
    var buf: [256]u8 = undefined;
    var w = HtmlWriter{ .buf = &buf, .pos = 0 };
    w.raw("<div class=\"meta\">Showing first ");
    w.write_u32(message.dashboard_list_max);
    w.raw("</div>");
    break :blk w.pos;
};

/// Collection detail: collection name + table of member products.
pub const collection_detail_max = comptime_render_size(message.CollectionWithProducts, render_collection_detail);

/// Order detail: order header + line items table.
pub const order_detail_max = comptime_render_size(message.OrderResult, render_order_detail);

/// SSE frame overhead: event line + longest selector + mode + "data: elements " + trailing newlines.
/// Measured at comptime by writing the framing with an empty body.
const sse_frame_overhead = blk: {
    var buf: [256]u8 = undefined;
    var w = HtmlWriter{ .buf = &buf, .pos = 0 };
    // Use longest selector form: "#col-" + 32-char UUID.
    const selector = id_selector("#col-", std.math.maxInt(u128));
    sse_event_begin(&w, &selector);
    sse_event_end(&w);
    break :blk w.pos;
};

/// Maximum size of an SSE error body: "<div class=\"error\">...</div>".
const sse_error_body_max = blk: {
    // Measure longest status string.
    var max_len: usize = 0;
    for (std.enums.values(message.Status)) |s| {
        max_len = @max(max_len, status_to_string(s).len);
    }
    break :blk "<div class=\"error\">".len + max_len + "</div>".len;
};

pub const send_buf_max = blk: {
    const product_list_body = message.dashboard_list_max * product_card_max + count_indicator_max;
    const collection_list_body = message.dashboard_list_max * collection_card_max + count_indicator_max;
    const order_list_body = message.dashboard_list_max * order_card_max + count_indicator_max;

    // HTML path: body starts at header_reserve, headers backfilled before it.
    const full_page = header_reserve + page_shell_max + product_list_body + collection_list_body + order_list_body;

    // Dashboard SSE sends 3 fragments (one per list). SSE writes from offset 0.
    const dashboard_sse = 3 * sse_frame_overhead + product_list_body + collection_list_body + order_list_body;

    // Follow-up SSE: 3 dashboard fragments + optional error fragment.
    const followup_sse = dashboard_sse + sse_frame_overhead + sse_error_body_max;

    // Single SSE list fragment.
    const sse_list = sse_frame_overhead +
        @max(product_list_body, @max(collection_list_body, order_list_body));

    // Single SSE detail fragment.
    const sse_detail = sse_frame_overhead +
        @max(collection_detail_max, order_detail_max);

    break :blk @max(full_page, @max(followup_sse, @max(dashboard_sse, @max(sse_list, sse_detail))));
};

comptime {
    assert(send_buf_max <= http.send_buf_max);
}

/// Run a renderer at comptime on worst-case input, return exact output size.
fn comptime_render_size(comptime T: type, comptime render_fn: *const fn (*HtmlWriter, *const T) void) usize {
    comptime {
        @setEvalBranchQuota(500_000);
        const item = worst_case(T);
        var buf: [256 * 1024]u8 = undefined;
        var w = HtmlWriter{ .buf = &buf, .pos = 0 };
        render_fn(&w, &item);
        return w.pos;
    }
}

/// Construct the worst-case input for a given type — maximum-length fields
/// filled with `"` (6x expansion in both html_escaped and js_escaped).
fn worst_case(comptime T: type) T {
    comptime {
        if (T == message.Product) {
            var p = std.mem.zeroes(message.Product);
            p.id = std.math.maxInt(u128);
            p.price_cents = std.math.maxInt(u32);
            p.inventory = std.math.maxInt(u32);
            p.version = std.math.maxInt(u32);
            p.flags = .{ .active = false }; // includes [inactive] span
            p.name_len = message.product_name_max;
            @memset(p.name[0..p.name_len], '"');
            p.description_len = message.product_description_max;
            @memset(p.description[0..p.description_len], '"');
            return p;
        } else if (T == message.ProductCollection) {
            var c = std.mem.zeroes(message.ProductCollection);
            c.id = std.math.maxInt(u128);
            c.name_len = message.collection_name_max;
            @memset(c.name[0..c.name_len], '"');
            return c;
        } else if (T == message.OrderSummary) {
            var o = std.mem.zeroes(message.OrderSummary);
            o.id = std.math.maxInt(u128);
            o.total_cents = std.math.maxInt(u64);
            o.items_len = message.order_items_max;
            o.status = .cancelled; // longest status string
            return o;
        } else if (T == message.CollectionWithProducts) {
            var cwp: message.CollectionWithProducts = undefined;
            cwp.collection = worst_case(message.ProductCollection);
            cwp.products.len = message.dashboard_list_max;
            for (cwp.products.items[0..cwp.products.len]) |*p| {
                p.* = worst_case(message.Product);
            }
            return cwp;
        } else if (T == message.OrderResult) {
            var o = std.mem.zeroes(message.OrderResult);
            o.id = std.math.maxInt(u128);
            o.total_cents = std.math.maxInt(u64);
            o.status = .pending; // includes Complete/Cancel buttons
            o.items_len = message.order_items_max;
            for (o.items[0..o.items_len]) |*item| {
                item.* = std.mem.zeroes(message.OrderResultItem);
                item.product_id = std.math.maxInt(u128);
                item.price_cents = std.math.maxInt(u32);
                item.quantity = std.math.maxInt(u32);
                item.line_total_cents = std.math.maxInt(u64);
                item.name_len = message.product_name_max;
                @memset(item.name[0..item.name_len], '"');
            }
            return o;
        } else {
            unreachable;
        }
    }
}

/// Encode a response as HTML page, SSE fragments, or SSE error.
pub const Response = struct {
    /// Byte offset into send_buf where the response starts.
    offset: u32,
    /// Total response length (headers + body).
    len: u32,
    /// Whether the connection can be reused.
    keep_alive: bool,
};

/// Reserve space for HTTP headers so we can backfill Content-Length.
/// "HTTP/1.1 200 OK\r\n" (18) +
/// "Content-Type: text/html; charset=utf-8\r\n" (40) +
/// "Content-Length: NNNNN\r\n" (23 max for 5-digit) +
/// "Cache-Control: no-cache\r\n" (25) +
/// "Connection: keep-alive\r\n" (24) +
/// "\r\n" (2) = 132.  Round up for safety.
const header_reserve: u32 = 192;

/// The result variant drives success encoding. For errors, `operation`
/// selects which UI panel to show the error in.
pub fn encode_response(send_buf: []u8, operation: message.Operation, resp: message.MessageResponse, is_datastar_request: bool) Response {
    assert(send_buf.len >= http.send_buf_max);

    // SSE responses write headers + body sequentially from offset 0.
    // Non-SSE responses write body at header_reserve, then backfill headers.
    if (is_datastar_request) {
        return encode_sse_response(send_buf, operation, resp);
    } else {
        return encode_html_response(send_buf, operation, resp);
    }
}

/// SSE follow-up: after an SSE mutation, the server runs page_load_dashboard
/// next tick and renders the full dashboard as SSE fragments. If the original
/// mutation failed, an error fragment is included targeting the relevant panel.
pub fn encode_followup(
    send_buf: []u8,
    dashboard: *const message.PageLoadDashboardResult,
    original_operation: message.Operation,
    followup_status: message.Status,
) Response {
    assert(send_buf.len >= http.send_buf_max);
    assert(is_mutation(original_operation));

    var w = HtmlWriter{ .buf = send_buf, .pos = 0 };
    encode_sse_headers(&w);

    // Dashboard fragments — always sent, even on error (data hasn't changed
    // but the refresh is harmless and keeps the UI in sync).
    encode_sse_fragment(&w, "#product-list", message.ProductList, &dashboard.products);
    encode_sse_fragment(&w, "#collection-list", message.CollectionList, &dashboard.collections);
    encode_sse_fragment(&w, "#order-list", message.OrderSummaryList, &dashboard.orders);

    // Error fragment if the original mutation failed.
    if (followup_status != .ok) {
        sse_event_begin(&w, error_selector(original_operation));
        w.raw("<div class=\"error\">");
        w.raw(status_to_string(followup_status));
        w.raw("</div>");
        sse_event_end(&w);
    }

    assert(w.pos > 0);
    return .{ .offset = 0, .len = @intCast(w.pos), .keep_alive = false };
}


/// SSE path: headers + body written sequentially. Connection: close.
fn encode_sse_response(send_buf: []u8, operation: message.Operation, resp: message.MessageResponse) Response {
    var w = HtmlWriter{ .buf = send_buf, .pos = 0 };

    if (resp.status != .ok) {
        assert(resp.result == .empty);
        encode_sse_error(&w, operation, resp.status);
    } else {
        assert(result_matches_operation(operation, resp.result));

        // Mutations over SSE are handled by encode_followup, not this path.
        assert(!is_mutation(operation));
        encode_sse_headers(&w);

        switch (resp.result) {
            .page_load_dashboard => |dashboard| {
                encode_sse_fragment(&w, "#product-list", message.ProductList, &dashboard.products);
                encode_sse_fragment(&w, "#collection-list", message.CollectionList, &dashboard.collections);
                encode_sse_fragment(&w, "#order-list", message.OrderSummaryList, &dashboard.orders);
            },
            .product_list => |list| {
                encode_sse_fragment(&w, "#product-list", message.ProductList, &list);
            },
            .collection_list => |list| {
                encode_sse_fragment(&w, "#collection-list", message.CollectionList, &list);
            },
            .order_list => |list| {
                encode_sse_fragment(&w, "#order-list", message.OrderSummaryList, &list);
            },
            .collection => |cwp| {
                const selector = id_selector("#col-", cwp.collection.id);
                sse_event_begin(&w, &selector);
                render_collection_detail(&w, &cwp);
                sse_event_end(&w);
            },
            .order => |order| {
                const selector = id_selector("#od-", order.id);
                sse_event_begin(&w, &selector);
                render_order_detail(&w, &order);
                sse_event_end(&w);
            },
            .product => |p| {
                const selector = id_selector("#pd-", p.id);
                sse_event_begin(&w, &selector);
                render_product_card(&w, &p);
                sse_event_end(&w);
            },
            .inventory => |inv| {
                sse_event_begin(&w, "#inventory");
                w.raw("inventory: ");
                w.write_u32(inv);
                sse_event_end(&w);
            },
            .empty => unreachable,
        }
    }
    assert(w.pos > 0);
    return .{ .offset = 0, .len = @intCast(w.pos), .keep_alive = false };
}

/// Non-SSE path: write body first at header_reserve, then backfill
/// headers with Content-Length. Enables HTTP keep-alive.
fn encode_html_response(send_buf: []u8, operation: message.Operation, resp: message.MessageResponse) Response {
    var w = HtmlWriter{ .buf = send_buf, .pos = header_reserve };

    if (resp.status != .ok) {
        assert(resp.result == .empty);
        // Render the full dashboard — gives the user the token input and
        // navigation instead of a dead-end error page.
        return encode_dashboard_page(send_buf);
    } else {
        assert(result_matches_operation(operation, resp.result));
        switch (resp.result) {
            .page_load_dashboard => |dashboard| encode_full_page(&w, &dashboard),
            .product_list => |list| render_product_cards(&w, &list),
            .collection_list => |list| render_collection_cards(&w, &list),
            .order_list => |list| render_order_cards(&w, &list),
            .collection => |cwp| render_collection_detail(&w, &cwp),
            .order => |order| render_order_detail(&w, &order),
            .product => |p| render_product_card(&w, &p),
            .inventory => |inv| {
                w.raw("inventory: ");
                w.write_u32(inv);
            },
            .empty => {
                w.raw("OK");
            },
        }
    }

    const body_len = w.pos - header_reserve;
    assert(body_len > 0);

    return backfill_headers(send_buf, body_len);
}

/// Write HTTP headers right-aligned into the reserved space before the body.
/// Always 200 OK — see design/002-always-200.md.
fn backfill_headers(send_buf: []u8, body_len: usize) Response {
    // Build headers into a stack buffer.
    var hdr_buf: [header_reserve]u8 = undefined;
    var h = HtmlWriter{ .buf = &hdr_buf, .pos = 0 };

    h.raw("HTTP/1.1 200 OK\r\n");
    h.raw("Content-Type: text/html; charset=utf-8\r\n");
    h.raw("Content-Length: ");
    var cl_buf: [10]u8 = undefined;
    h.raw(stdx.format_u32(&cl_buf, @intCast(body_len)));
    h.raw("\r\nConnection: keep-alive\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "\r\n");

    assert(h.pos <= header_reserve);

    // Copy headers right-aligned so they abut the body.
    const start = header_reserve - h.pos;
    @memcpy(send_buf[start..][0..h.pos], hdr_buf[0..h.pos]);

    return .{
        .offset = @intCast(start),
        .len = @intCast(h.pos + body_len),
        .keep_alive = true,
    };
}

/// Render the full dashboard page with empty lists. Used for auth failures
/// and non-SSE errors — the user sees the page with the token input.
fn encode_dashboard_page(send_buf: []u8) Response {
    var w = HtmlWriter{ .buf = send_buf, .pos = header_reserve };
    encode_full_page(&w, &empty_dashboard);
    const body_len = w.pos - header_reserve;
    assert(body_len > 0);
    return backfill_headers(send_buf, body_len);
}

// --- Full HTML page ---

fn encode_full_page(w: *HtmlWriter, dashboard: *const message.PageLoadDashboardResult) void {
    // DOCTYPE + head
    w.raw("<!DOCTYPE html>\n<html>\n<head>\n" ++
        "<meta charset=\"utf-8\">\n" ++
        "<title>Tiger Web</title>\n" ++
        "<script type=\"module\" src=\"https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.7/bundles/datastar.js\"></script>\n" ++
        "<style>\n" ++
        "* { box-sizing: border-box; margin: 0; padding: 0; }\n" ++
        "body { font-family: system-ui, sans-serif; background: #f5f5f5; color: #333; padding: 20px; }\n" ++
        "h1 { margin-bottom: 16px; font-size: 22px; }\n" ++
        "h2 { margin: 20px 0 8px; font-size: 16px; border-bottom: 1px solid #ccc; padding-bottom: 4px; }\n" ++
        "button { cursor: pointer; padding: 4px 12px; border: 1px solid #999; border-radius: 3px; background: #fff; }\n" ++
        "button:hover { background: #eee; }\n" ++
        "button.danger { color: #c00; }\n" ++
        "input, select { padding: 4px 8px; border: 1px solid #ccc; border-radius: 3px; }\n" ++
        ".row { display: flex; gap: 8px; align-items: center; margin: 6px 0; flex-wrap: wrap; }\n" ++
        ".card { background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: 12px; margin: 8px 0; }\n" ++
        ".card .meta { font-size: 12px; color: #888; }\n" ++
        ".error { color: #f44; }\n" ++
        ".ok { color: #4a4; }\n" ++
        "table { border-collapse: collapse; width: 100%; }\n" ++
        "th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid #eee; font-size: 13px; }\n" ++
        "th { background: #f0f0f0; }\n" ++
        "section { margin-bottom: 24px; }\n" ++
        ".cols { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }\n" ++
        "@media (max-width: 800px) { .cols { grid-template-columns: 1fr; } }\n" ++
        "</style>\n" ++
        "</head>\n");

    // Body with Datastar signals
    w.raw("<body\n" ++
        "  data-signals=\"{\n" ++
        "    token: '',\n" ++
        "    _pName: '', _pDesc: '', _pPrice: 999, _pInv: 10,\n" ++
        "    _pActive: '', _pPrefix: '',\n" ++
        "    _cName: '',\n" ++
        "    _oItems: '',\n" ++
        "    _tSrc: '', _tDst: '', _tQty: 1\n" ++
        "  }\"\n" ++
        ">\n\n");

    w.raw("<h1>Tiger Web</h1>\n\n");

    // Token input + Refresh All
    w.raw("<div class=\"row\">\n" ++
        "  <label>Token: <input data-bind:token style=\"width:360px\"></label>\n" ++
        "  <button data-on:click=\"\n" ++
        "    @get('/products', {headers: {'Authorization': 'Bearer ' + $token}});\n" ++
        "    @get('/collections', {headers: {'Authorization': 'Bearer ' + $token}});\n" ++
        "    @get('/orders', {headers: {'Authorization': 'Bearer ' + $token}})\n" ++
        "  \">Refresh All</button>\n" ++
        "</div>\n\n");

    w.raw("<div class=\"cols\">\n<div>\n\n");

    // --- Products section ---
    w.raw("<section>\n<h2>Products</h2>\n");
    w.raw("<div class=\"row\">\n" ++
        "  <input data-bind:_p-name placeholder=\"Name\" style=\"width:120px\">\n" ++
        "  <input data-bind:_p-desc placeholder=\"Description\" style=\"width:140px\">\n" ++
        "  <input data-bind:_p-price placeholder=\"Price (cents)\" type=\"number\" style=\"width:100px\">\n" ++
        "  <input data-bind:_p-inv placeholder=\"Inventory\" type=\"number\" style=\"width:80px\">\n" ++
        "  <button data-on:click=\"\n" ++
        "    @post('/products', {\n" ++
        "      headers: {'Authorization': 'Bearer ' + $token},\n" ++
        "      payload: {\n" ++
        "        id: uuid(), name: $_pName || 'Test Product', description: $_pDesc,\n" ++
        "        price_cents: +$_pPrice || 999, inventory: +$_pInv || 10, active: true\n" ++
        "      }\n" ++
        "    })\n" ++
        "  \">Create</button>\n" ++
        "</div>\n");
    w.raw("<div class=\"row\">\n" ++
        "  <label>Filter: <select data-bind:_p-active>\n" ++
        "    <option value=\"\">active (default)</option>\n" ++
        "    <option value=\"all\">all</option>\n" ++
        "    <option value=\"false\">inactive</option>\n" ++
        "  </select></label>\n" ++
        "  <input data-bind:_p-prefix placeholder=\"Name prefix\" style=\"width:100px\">\n" ++
        "  <button data-on:click=\"\n" ++
        "    let qs = '';\n" ++
        "    if ($_pActive) qs += '?active=' + $_pActive;\n" ++
        "    if ($_pPrefix) qs += (qs ? '&' : '?') + 'name_prefix=' + encodeURIComponent($_pPrefix);\n" ++
        "    @get('/products' + qs, {headers: {'Authorization': 'Bearer ' + $token}})\n" ++
        "  \">List</button>\n" ++
        "</div>\n");
    w.raw("<div id=\"product-list\">\n");
    render_product_cards(w, &dashboard.products);
    w.raw("</div>\n</section>\n\n");

    // --- Inventory Transfer section ---
    w.raw("<section>\n<h2>Inventory Transfer</h2>\n" ++
        "<div class=\"row\">\n" ++
        "  <input data-bind:_t-src placeholder=\"Source product ID\" style=\"width:260px\">\n" ++
        "  <input data-bind:_t-dst placeholder=\"Target product ID\" style=\"width:260px\">\n" ++
        "  <input data-bind:_t-qty placeholder=\"Qty\" type=\"number\" style=\"width:70px\">\n" ++
        "  <button data-on:click=\"\n" ++
        "    if (!$_tSrc || !$_tDst) { alert('Enter source and target product IDs'); return; }\n" ++
        "    @post('/products/' + $_tSrc + '/transfer-inventory/' + $_tDst, {\n" ++
        "      headers: {'Authorization': 'Bearer ' + $token},\n" ++
        "      payload: {quantity: +$_tQty || 1}\n" ++
        "    })\n" ++
        "  \">Transfer</button>\n" ++
        "</div>\n</section>\n\n");

    w.raw("</div>\n<div>\n\n");

    // --- Collections section ---
    w.raw("<section>\n<h2>Collections</h2>\n" ++
        "<div class=\"row\">\n" ++
        "  <input data-bind:_c-name placeholder=\"Collection name\" style=\"width:180px\">\n" ++
        "  <button data-on:click=\"\n" ++
        "    @post('/collections', {\n" ++
        "      headers: {'Authorization': 'Bearer ' + $token},\n" ++
        "      payload: {id: uuid(), name: $_cName || 'Test Collection'}\n" ++
        "    })\n" ++
        "  \">Create</button>\n" ++
        "  <button data-on:click=\"\n" ++
        "    @get('/collections', {headers: {'Authorization': 'Bearer ' + $token}})\n" ++
        "  \">List</button>\n" ++
        "</div>\n");
    w.raw("<div id=\"collection-list\">\n");
    render_collection_cards(w, &dashboard.collections);
    w.raw("</div>\n</section>\n\n");

    // --- Orders section ---
    w.raw("<section>\n<h2>Orders</h2>\n" ++
        "<div class=\"row\">\n" ++
        "  <input data-bind:_o-items placeholder=\"Product IDs (comma-sep), qty=1 each\" style=\"width:400px\">\n" ++
        "  <button data-on:click=\"\n" ++
        "    if (!$_oItems) { alert('Enter product IDs'); return; }\n" ++
        "    const ids = $_oItems.split(',').map(s => s.trim()).filter(Boolean);\n" ++
        "    const items = ids.map(id => ({product_id: id, quantity: 1}));\n" ++
        "    @post('/orders', {\n" ++
        "      headers: {'Authorization': 'Bearer ' + $token},\n" ++
        "      payload: {id: uuid(), items}\n" ++
        "    })\n" ++
        "  \">Create Order</button>\n" ++
        "  <button data-on:click=\"\n" ++
        "    @get('/orders', {headers: {'Authorization': 'Bearer ' + $token}})\n" ++
        "  \">List Orders</button>\n" ++
        "</div>\n");
    w.raw("<div id=\"order-list\">\n");
    render_order_cards(w, &dashboard.orders);
    w.raw("</div>\n</section>\n\n");

    w.raw("</div>\n</div>\n\n");

    // UUID helper script
    w.raw("<script>\n" ++
        "function uuid() {\n" ++
        "  const b = new Uint8Array(16);\n" ++
        "  crypto.getRandomValues(b);\n" ++
        "  return Array.from(b, x => x.toString(16).padStart(2, '0')).join('');\n" ++
        "}\n" ++
        "</script>\n\n");

    w.raw("</body>\n</html>\n");
}

// --- Card renderers ---

const auth_opt = "{headers:{'Authorization':'Bearer '+$token}}";

fn render_product_cards(w: *HtmlWriter, list: *const message.ProductList) void {
    assert(list.len <= message.list_max);
    if (list.len == 0) {
        w.raw("<div class=\"card\">No products</div>");
        return;
    }
    const display_len = @min(list.len, message.dashboard_list_max);
    for (list.items[0..display_len]) |*p| {
        render_product_card(w, p);
    }
    if (list.len >= message.dashboard_list_max) {
        w.raw("<div class=\"meta\">Showing first ");
        w.write_u32(message.dashboard_list_max);
        w.raw("</div>");
    }
}

fn render_product_card(w: *HtmlWriter, p: *const message.Product) void {
    w.raw("<div class=\"card\"><strong>");
    w.html_escaped(p.name_slice());
    w.raw("</strong> &mdash; ");
    w.write_price(p.price_cents);
    w.raw(" &mdash; inv: ");
    w.write_u32(p.inventory);
    w.raw(" &mdash; v");
    w.write_u32(p.version);
    if (!p.flags.active) {
        w.raw(" <span class=\"error\">[inactive]</span>");
    }
    w.raw("<div class=\"meta\">");
    w.write_uuid(p.id);
    w.raw("</div><div class=\"meta\">");
    w.html_escaped(p.description_slice());
    w.raw("</div><div class=\"row\" style=\"margin-top:4px\">");

    // Delete button
    w.raw("<button data-on:click=\"@delete('/products/");
    w.write_uuid(p.id);
    w.raw("'," ++ auth_opt ++ ")\">Delete</button> ");

    // Update button
    w.raw("<button data-on:click=\"const n=prompt('New name:','");
    w.js_escaped(p.name_slice());
    w.raw("'); if(!n) return; const pr=parseInt(prompt('New price (cents):',");
    w.write_u32(p.price_cents);
    w.raw(")); if(isNaN(pr)) return; @put('/products/");
    w.write_uuid(p.id);
    w.raw("',{headers:{'Authorization':'Bearer '+$token},payload:{name:n,price_cents:pr,version:");
    w.write_u32(p.version);
    w.raw("}})\">Update</button>");

    w.raw("</div></div>");
}

fn render_collection_cards(w: *HtmlWriter, list: *const message.CollectionList) void {
    assert(list.len <= message.list_max);
    if (list.len == 0) {
        w.raw("<div class=\"card\">No collections</div>");
        return;
    }
    const display_len = @min(list.len, message.dashboard_list_max);
    for (list.items[0..display_len]) |*c| {
        render_collection_card(w, c);
    }
    if (list.len >= message.dashboard_list_max) {
        w.raw("<div class=\"meta\">Showing first ");
        w.write_u32(message.dashboard_list_max);
        w.raw("</div>");
    }
}

fn render_collection_card(w: *HtmlWriter, c: *const message.ProductCollection) void {
    w.raw("<div class=\"card\"><strong>");
    w.html_escaped(c.name_slice());
    w.raw("</strong><div class=\"meta\">");
    w.write_uuid(c.id);
    w.raw("</div><div class=\"row\" style=\"margin-top:4px\">");

    // View button
    w.raw("<button data-on:click=\"@get('/collections/");
    w.write_uuid(c.id);
    w.raw("'," ++ auth_opt ++ ")\">View</button> ");

    // Delete button
    w.raw("<button class=\"danger\" data-on:click=\"@delete('/collections/");
    w.write_uuid(c.id);
    w.raw("'," ++ auth_opt ++ ")\">Delete</button> ");

    // Add product input + button
    w.raw("<input id=\"add-");
    w.write_uuid(c.id);
    w.raw("\" placeholder=\"Product ID\" style=\"width:260px\"> ");
    w.raw("<button data-on:click=\"const pid=document.getElementById('add-");
    w.write_uuid(c.id);
    w.raw("').value; if(!pid){alert('Enter a product ID');return;} @post('/collections/");
    w.write_uuid(c.id);
    w.raw("/products/'+pid," ++ auth_opt ++ ")\">Add Product</button>");

    // Detail container
    w.raw("</div><div id=\"col-");
    w.write_uuid(c.id);
    w.raw("\"></div></div>");
}

fn render_order_cards(w: *HtmlWriter, list: *const message.OrderSummaryList) void {
    assert(list.len <= message.list_max);
    if (list.len == 0) {
        w.raw("<div class=\"card\">No orders</div>");
        return;
    }
    const display_len = @min(list.len, message.dashboard_list_max);
    for (list.items[0..display_len]) |*o| {
        render_order_card(w, o);
    }
    if (list.len >= message.dashboard_list_max) {
        w.raw("<div class=\"meta\">Showing first ");
        w.write_u32(message.dashboard_list_max);
        w.raw("</div>");
    }
}

fn render_order_card(w: *HtmlWriter, o: *const message.OrderSummary) void {
    w.raw("<div class=\"card\">Order <strong>");
    w.write_short_uuid(o.id);
    w.raw("...</strong> &mdash; ");
    w.raw(switch (o.status) {
        .pending => "Pending",
        .confirmed => "Confirmed",
        .failed => "Failed",
        .cancelled => "Cancelled",
    });
    w.raw(" &mdash; ");
    w.write_price(o.total_cents);
    w.raw(" &mdash; ");
    w.write_u32(@intCast(o.items_len));
    w.raw(" items ");

    // Details button
    w.raw("<button data-on:click=\"@get('/orders/");
    w.write_uuid(o.id);
    w.raw("'," ++ auth_opt ++ ")\">Details</button>");
    w.raw("<div id=\"od-");
    w.write_uuid(o.id);
    w.raw("\"></div></div>");
}

// --- Detail renderers ---

fn render_collection_detail(w: *HtmlWriter, cwp: *const message.CollectionWithProducts) void {
    w.raw("<strong>");
    w.html_escaped(cwp.collection.name_slice());
    w.raw("</strong>");
    const products = &cwp.products;
    if (products.len == 0) {
        w.raw("<div class=\"meta\">No products</div>");
        return;
    }
    w.raw("<table><tr><th>Product</th><th>Price</th><th>Inv</th><th></th></tr>");
    const display_len = @min(products.len, message.dashboard_list_max);
    for (products.items[0..display_len]) |*p| {
        w.raw("<tr><td>");
        w.html_escaped(p.name_slice());
        w.raw("</td><td>");
        w.write_price(p.price_cents);
        w.raw("</td><td>");
        w.write_u32(p.inventory);
        w.raw("</td><td><button class=\"danger\" data-on:click=\"@delete('/collections/");
        w.write_uuid(cwp.collection.id);
        w.raw("/products/");
        w.write_uuid(p.id);
        w.raw("'," ++ auth_opt ++ ")\">Remove</button></td></tr>");
    }
    w.raw("</table>");
    if (products.len >= message.dashboard_list_max) {
        w.raw("<div class=\"meta\">Showing first ");
        w.write_u32(message.dashboard_list_max);
        w.raw("</div>");
    }
}

fn render_order_detail(w: *HtmlWriter, order: *const message.OrderResult) void {
    w.raw("<strong>");
    w.write_short_uuid(order.id);
    w.raw("...</strong> &mdash; ");
    w.raw(switch (order.status) {
        .pending => "Pending",
        .confirmed => "Confirmed",
        .failed => "Failed",
        .cancelled => "Cancelled",
    });
    w.raw(" &mdash; ");
    w.write_price(order.total_cents);
    if (order.items_len == 0) {
        w.raw("<div class=\"meta\">No items</div>");
        return;
    }
    w.raw("<table><tr><th>Product</th><th>Qty</th><th>Price</th><th>Line Total</th></tr>");
    for (order.items[0..order.items_len]) |*item| {
        w.raw("<tr><td>");
        w.html_escaped(item.name_slice());
        w.raw("</td><td>");
        w.write_u32(item.quantity);
        w.raw("</td><td>");
        w.write_price(item.price_cents);
        w.raw("</td><td>");
        w.write_price(item.line_total_cents);
        w.raw("</td></tr>");
    }
    w.raw("<tr><td colspan=\"3\"><strong>Total</strong></td><td><strong>");
    w.write_price(order.total_cents);
    w.raw("</strong></td></tr></table>");
    if (order.status == .pending) {
        w.raw("<div class=\"row\" style=\"margin-top:4px\">");
        w.raw("<button data-on:click=\"@post('/orders/");
        w.write_uuid(order.id);
        w.raw("/complete'," ++ auth_opt ++ ")\">Complete</button> ");
        w.raw("<button class=\"danger\" data-on:click=\"@post('/orders/");
        w.write_uuid(order.id);
        w.raw("/cancel'," ++ auth_opt ++ ")\">Cancel</button>");
        w.raw("</div>");
    }
}

// --- SSE framing ---

fn encode_sse_headers(w: *HtmlWriter) void {
    w.raw("HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: close\r\n" ++
        "\r\n");
}

/// Build a selector like "#col-aabbccdd11223344aabbccdd11223344" on the stack.
fn id_selector(comptime prefix: []const u8, id: u128) [prefix.len + 32]u8 {
    var buf: [prefix.len + 32]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    stdx.write_uuid_to_buf(buf[prefix.len..][0..32], id);
    return buf;
}

/// Begin an SSE patch-elements event: writes event line, selector, mode, and
/// "data: elements " prefix. Caller writes content, then calls sse_event_end.
fn sse_event_begin(w: *HtmlWriter, selector: []const u8) void {
    w.raw("event: datastar-patch-elements\n" ++
        "data: selector ");
    w.raw(selector);
    w.raw("\ndata: mode inner\n" ++
        "data: elements ");
}

fn sse_event_end(w: *HtmlWriter) void {
    w.raw("\n\n");
}

fn encode_sse_fragment(w: *HtmlWriter, selector: []const u8, comptime ListType: type, list: *const ListType) void {
    sse_event_begin(w, selector);
    switch (ListType) {
        message.ProductList => render_product_cards(w, list),
        message.CollectionList => render_collection_cards(w, list),
        message.OrderSummaryList => render_order_cards(w, list),
        else => unreachable,
    }
    sse_event_end(w);
}

// --- Non-SSE body helpers ---

// --- Error responses ---

fn encode_sse_error(w: *HtmlWriter, operation: message.Operation, status: message.Status) void {
    encode_sse_headers(w);
    sse_event_begin(w, error_selector(operation));
    w.raw("<div class=\"error\">");
    w.raw(status_to_string(status));
    w.raw("</div>");
    sse_event_end(w);
}

/// Pair assertion: the result variant must match the operation that produced it.
/// Catches misrouted responses — e.g. a product result on a collection operation.
pub fn is_mutation(operation: message.Operation) bool {
    return switch (operation) {
        .page_load_dashboard,
        .list_products, .list_collections, .list_orders,
        .get_product, .get_collection, .get_order,
        .get_product_inventory, .search_products,
        => false,
        .create_product, .update_product, .delete_product,
        .create_collection, .delete_collection,
        .add_collection_member, .remove_collection_member,
        .create_order, .complete_order, .cancel_order,
        .transfer_inventory,
        => true,
    };
}

fn result_matches_operation(operation: message.Operation, result: message.Result) bool {
    return switch (operation) {
        .page_load_dashboard => result == .page_load_dashboard,
        .list_products => result == .product_list,
        .list_collections => result == .collection_list,
        .list_orders => result == .order_list,
        .get_collection => result == .collection,
        .get_order => result == .order,
        .create_product, .update_product, .get_product => result == .product,
        .get_product_inventory => result == .inventory,
        .transfer_inventory => result == .product_list,
        .create_order, .complete_order, .cancel_order => result == .order,
        .search_products => result == .product_list,
        .create_collection => result == .collection,
        .delete_product, .delete_collection,
        .add_collection_member, .remove_collection_member,
        => result == .empty,
    };
}

fn error_selector(operation: message.Operation) []const u8 {
    return switch (operation) {
        .create_product, .update_product, .get_product,
        .delete_product, .get_product_inventory,
        .transfer_inventory, .search_products,
        .list_products,
        => "#product-list",
        .create_collection, .delete_collection,
        .add_collection_member, .remove_collection_member,
        .get_collection, .list_collections,
        => "#collection-list",
        .create_order, .complete_order, .cancel_order,
        .get_order, .list_orders,
        => "#order-list",
        .page_load_dashboard => "#product-list",
    };
}

fn status_to_string(status: message.Status) []const u8 {
    return switch (status) {
        .ok => "OK",
        .not_found => "Not Found",
        .storage_error => "Service Unavailable",
        .insufficient_inventory => "Insufficient Inventory",
        .version_conflict => "Version Conflict",
        .order_expired => "Order Expired",
        .order_not_pending => "Order Not Pending",
        .unauthorized => "Unauthorized",
    };
}

// --- HtmlWriter ---

const HtmlWriter = struct {
    buf: []u8,
    pos: usize,

    fn raw(self: *HtmlWriter, s: []const u8) void {
        assert(self.pos + s.len <= self.buf.len);
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    /// Escape HTML special characters: < > & " '
    /// Control characters (< 0x20) are stripped — they have no useful
    /// display form in HTML and would break SSE framing if they contain \n.
    fn html_escaped(self: *HtmlWriter, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '<' => self.raw("&lt;"),
                '>' => self.raw("&gt;"),
                '&' => self.raw("&amp;"),
                '"' => self.raw("&quot;"),
                '\'' => self.raw("&#39;"),
                else => {
                    if (c < 0x20) continue;
                    assert(self.pos < self.buf.len);
                    self.buf[self.pos] = c;
                    self.pos += 1;
                },
            }
        }
    }

    /// Escape for use in a single-quoted JS literal inside a double-quoted HTML attribute.
    /// Must handle: JS string breakers (\, ', \n, \r) and HTML attribute breakers (").
    fn js_escaped(self: *HtmlWriter, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '\\' => self.raw("\\\\"),
                '\'' => self.raw("\\'"),
                '"' => self.raw("&quot;"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                else => {
                    // Skip control characters — they shouldn't appear in
                    // HTML attributes and have no useful display form.
                    if (c < 0x20) continue;
                    assert(self.pos < self.buf.len);
                    self.buf[self.pos] = c;
                    self.pos += 1;
                },
            }
        }
    }

    fn write_u32(self: *HtmlWriter, val: u32) void {
        var num_buf: [10]u8 = undefined;
        const s = stdx.format_u32(&num_buf, val);
        self.raw(s);
    }

    fn write_u64(self: *HtmlWriter, val: u64) void {
        var num_buf: [20]u8 = undefined;
        const s = stdx.format_u64(&num_buf, val);
        self.raw(s);
    }

    fn write_uuid(self: *HtmlWriter, val: u128) void {
        var uuid_buf: [32]u8 = undefined;
        stdx.write_uuid_to_buf(&uuid_buf, val);
        self.raw(&uuid_buf);
    }

    /// First 8 hex chars of a UUID.
    fn write_short_uuid(self: *HtmlWriter, val: u128) void {
        var uuid_buf: [32]u8 = undefined;
        stdx.write_uuid_to_buf(&uuid_buf, val);
        self.raw(uuid_buf[0..8]);
    }

    /// Format "$D.CC" from cents.
    fn write_price(self: *HtmlWriter, cents: u64) void {
        self.raw("$");
        self.write_u64(cents / 100);
        self.raw(".");
        const cc: u32 = @intCast(cents % 100);
        if (cc < 10) self.raw("0");
        self.write_u32(cc);
    }
};

// format_u32, format_u64, write_uuid_to_buf are in stdx.zig.

// =====================================================================
// Tests
// =====================================================================

test "encode_response full page — empty dashboard" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .page_load_dashboard = .{
            .products = .{ .items = undefined, .len = 0 },
            .collections = .{ .items = undefined, .len = 0 },
            .orders = .{ .items = undefined, .len = 0 },
        } },
    };
    const r = encode_response(&send_buf, .page_load_dashboard, resp, false);
    assert(r.len > 0);
    assert(r.offset + r.len <= send_buf.len);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    assert(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
    assert(std.mem.indexOf(u8, output, "product-list") != null);
    assert(std.mem.indexOf(u8, output, "No products") != null);
}

test "encode_response SSE — empty dashboard" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .page_load_dashboard = .{
            .products = .{ .items = undefined, .len = 0 },
            .collections = .{ .items = undefined, .len = 0 },
            .orders = .{ .items = undefined, .len = 0 },
        } },
    };
    const r = encode_response(&send_buf, .page_load_dashboard, resp, true);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
    assert(std.mem.indexOf(u8, output, "event: datastar-patch-elements") != null);
    assert(std.mem.indexOf(u8, output, "#product-list") != null);
}

test "encode_response error — renders dashboard page for recovery" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    const resp = message.MessageResponse.storage_error;
    const r = encode_response(&send_buf, .page_load_dashboard, resp, false);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    assert(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
    assert(std.mem.indexOf(u8, output, "data-bind:token") != null);
    assert(r.keep_alive);
}

test "unauthorized — full page with token input" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    const r = encode_response(&send_buf, .page_load_dashboard, .{ .status = .unauthorized, .result = .{ .empty = {} } }, false);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    assert(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
    assert(std.mem.indexOf(u8, output, "data-bind:token") != null);
    assert(r.keep_alive);
    assert(std.mem.indexOf(u8, output, "Content-Length:") != null);
}

test "unauthorized — SSE error fragment" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    const r = encode_response(&send_buf, .page_load_dashboard, .{ .status = .unauthorized, .result = .{ .empty = {} } }, true);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
    assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
    assert(std.mem.indexOf(u8, output, "Unauthorized") != null);
    assert(!r.keep_alive);
}

test "encode_response with products" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    var products = message.ProductList{ .items = undefined, .len = 1 };
    products.items[0] = std.mem.zeroes(message.Product);
    products.items[0].id = 0xaabbccdd11223344aabbccdd11223344;
    products.items[0].name_len = 6;
    products.items[0].price_cents = 999;
    products.items[0].inventory = 10;
    products.items[0].version = 1;
    products.items[0].flags = .{ .active = true };
    @memcpy(products.items[0].name[0..6], "Widget");

    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .page_load_dashboard = .{
            .products = products,
            .collections = .{ .items = undefined, .len = 0 },
            .orders = .{ .items = undefined, .len = 0 },
        } },
    };
    const r = encode_response(&send_buf, .page_load_dashboard, resp, false);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.indexOf(u8, output, "Widget") != null);
    assert(std.mem.indexOf(u8, output, "$9.99") != null);
}

test "encode_response SSE — product list" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    var products = message.ProductList{ .items = undefined, .len = 1 };
    products.items[0] = std.mem.zeroes(message.Product);
    products.items[0].id = 0xaabbccdd11223344aabbccdd11223344;
    products.items[0].name_len = 6;
    products.items[0].price_cents = 999;
    products.items[0].inventory = 10;
    products.items[0].version = 1;
    products.items[0].flags = .{ .active = true };
    @memcpy(products.items[0].name[0..6], "Widget");

    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .product_list = products },
    };
    const r = encode_response(&send_buf, .list_products, resp, true);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
    assert(std.mem.indexOf(u8, output, "#product-list") != null);
    assert(std.mem.indexOf(u8, output, "Widget") != null);
}

test "encode_response SSE — collection detail" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    var col = std.mem.zeroes(message.ProductCollection);
    col.id = 0xcc000000000000000000000000000001;
    col.name_len = 4;
    @memcpy(col.name[0..4], "Sale");

    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .collection = .{
            .collection = col,
            .products = .{ .items = undefined, .len = 0 },
        } },
    };
    const r = encode_response(&send_buf, .get_collection, resp, true);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.indexOf(u8, output, "#col-cc000000000000000000000000000001") != null);
    assert(std.mem.indexOf(u8, output, "Sale") != null);
}

test "encode_response SSE — order detail" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    var order = std.mem.zeroes(message.OrderResult);
    order.id = 0xee000000000000000000000000000001;
    order.total_cents = 1998;
    order.status = .pending;
    order.items_len = 1;
    order.items[0] = std.mem.zeroes(message.OrderResultItem);
    order.items[0].name_len = 6;
    order.items[0].quantity = 2;
    order.items[0].price_cents = 999;
    order.items[0].line_total_cents = 1998;
    @memcpy(order.items[0].name[0..6], "Widget");

    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .order = order },
    };
    const r = encode_response(&send_buf, .get_order, resp, true);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.indexOf(u8, output, "#od-ee000000000000000000000000000001") != null);
    assert(std.mem.indexOf(u8, output, "Widget") != null);
    assert(std.mem.indexOf(u8, output, "Complete") != null);
    assert(std.mem.indexOf(u8, output, "Cancel") != null);
}

test "encode_response SSE error — targets correct selector" {
    var send_buf: [http.send_buf_max]u8 = undefined;
    const resp = message.MessageResponse.not_found;

    // list_orders error should target #order-list
    const r = encode_response(&send_buf, .list_orders, resp, true);
    assert(r.len > 0);
    const output = send_buf[r.offset..][0..r.len];
    assert(std.mem.indexOf(u8, output, "#order-list") != null);
    assert(std.mem.indexOf(u8, output, "Not Found") != null);
}

test "html_escaped handles special chars" {
    var buf: [256]u8 = undefined;
    var w = HtmlWriter{ .buf = &buf, .pos = 0 };
    w.html_escaped("<script>alert('xss')</script>");
    const result = buf[0..w.pos];
    assert(std.mem.indexOf(u8, result, "<") == null);
    assert(std.mem.indexOf(u8, result, "&lt;") != null);
    assert(std.mem.indexOf(u8, result, "&#39;") != null);
}

test "js_escaped handles quotes and backslashes" {
    var buf: [256]u8 = undefined;
    var w = HtmlWriter{ .buf = &buf, .pos = 0 };
    w.js_escaped("it's a \"test\" with \\backslash");
    const result = buf[0..w.pos];
    // Single quotes escaped for JS
    assert(std.mem.indexOf(u8, result, "\\'") != null);
    // Double quotes escaped for HTML attribute context
    assert(std.mem.indexOf(u8, result, "&quot;") != null);
    // Backslashes escaped
    assert(std.mem.indexOf(u8, result, "\\\\") != null);
    // No raw single quotes
    var raw_quotes: usize = 0;
    for (result, 0..) |c, i| {
        if (c == '\'' and (i == 0 or result[i - 1] != '\\')) raw_quotes += 1;
    }
    assert(raw_quotes == 0);
}

test "worst-case card rendering — comptime and runtime agree" {
    // Pair assertion: the comptime-derived card_max constants must match
    // the runtime renderer output on the same worst-case input.
    // If these diverge, either comptime evaluation or runtime codegen has a bug.
    const cases = .{
        .{ message.Product, render_product_card, product_card_max },
        .{ message.ProductCollection, render_collection_card, collection_card_max },
        .{ message.OrderSummary, render_order_card, order_card_max },
    };
    inline for (cases) |case| {
        const T = case[0];
        const render_fn = case[1];
        const card_max = case[2];
        const item = comptime worst_case(T);
        var buf: [card_max]u8 = undefined;
        var w = HtmlWriter{ .buf = &buf, .pos = 0 };
        render_fn(&w, &item);
        assert(w.pos == card_max);
    }
}

test "write_price formatting" {
    var buf: [64]u8 = undefined;
    var w = HtmlWriter{ .buf = &buf, .pos = 0 };
    w.write_price(999);
    try std.testing.expectEqualSlices(u8, buf[0..w.pos], "$9.99");

    w.pos = 0;
    w.write_price(100);
    try std.testing.expectEqualSlices(u8, buf[0..w.pos], "$1.00");

    w.pos = 0;
    w.write_price(5);
    try std.testing.expectEqualSlices(u8, buf[0..w.pos], "$0.05");

    w.pos = 0;
    w.write_price(0);
    try std.testing.expectEqualSlices(u8, buf[0..w.pos], "$0.00");
}
