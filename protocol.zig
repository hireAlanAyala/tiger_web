//! Sidecar wire protocol — fixed-size binary messages between the Zig
//! framework and the TypeScript sidecar over a unix socket.
//!
//! Two round trips per HTTP request:
//!   1. Translate: method + path + body → operation + id + typed event
//!   2. Execute + Render: operation + cache → status + writes + HTML
//!
//! Both round trips defined here as extern structs with no padding.

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("tiger_framework").stdx;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const SM = state_machine.StateMachineType(state_machine.MemoryStorage);
const render = @import("render.zig");

/// Maximum URL path length in the translate request.
pub const path_max = 256;

/// Maximum raw HTTP body (JSON text) in the translate request.
pub const json_body_max = 4096;

/// Protocol message tag — identifies the round trip type.
pub const Tag = enum(u8) {
    translate = 0x01,
    execute_render = 0x02,
};

/// HTTP method — subset relevant to the application.
pub const Method = enum(u8) {
    get = 1,
    post = 2,
    put = 3,
    delete = 4,
};

/// Translate request: Zig → sidecar.
/// Carries the raw HTTP request for the sidecar to route and parse.
/// Fields ordered to avoid padding: small fields first, then arrays.
pub const TranslateRequest = extern struct {
    tag: Tag,
    method: Method,
    path_len: u16,
    body_len: u16,
    reserved: [2]u8,
    path: [path_max]u8,
    body: [json_body_max]u8,

    comptime {
        assert(stdx.no_padding(TranslateRequest));
        // tag(1) + method(1) + path_len(2) + body_len(2) + reserved(2)
        // + path(256) + body(4096) = 4360
        assert(@sizeOf(TranslateRequest) == 4360);
        assert(path_max > 0);
        assert(path_max <= std.math.maxInt(u16));
        assert(json_body_max > 0);
        assert(json_body_max <= std.math.maxInt(u16));
    }

    pub fn path_slice(self: *const TranslateRequest) []const u8 {
        assert(self.path_len <= path_max);
        return self.path[0..self.path_len];
    }

    pub fn body_slice(self: *const TranslateRequest) []const u8 {
        assert(self.body_len <= json_body_max);
        return self.body[0..self.body_len];
    }
};

/// Translate response: sidecar → Zig.
/// Carries the routed operation and typed event body.
/// Fields ordered largest-alignment first to avoid padding.
pub const TranslateResponse = extern struct {
    id: u128,
    body: [message.body_max]u8,
    found: u8,
    operation: message.Operation,
    reserved: [14]u8,

    comptime {
        assert(stdx.no_padding(TranslateResponse));
        // id(16) + body(672) + found(1) + operation(1) + reserved(14) = 704
        assert(@sizeOf(TranslateResponse) == 704);
        // Size must be aligned to u128 alignment (16 bytes).
        assert(@sizeOf(TranslateResponse) % @alignOf(u128) == 0);
    }

    /// Returns true if the sidecar found a matching route.
    pub fn is_found(self: *const TranslateResponse) bool {
        assert(self.found == 0 or self.found == 1);
        return self.found == 1;
    }
};

// -----------------------------------------------------------------------
// Round trip 2: Execute + Render
// -----------------------------------------------------------------------

/// Maximum HTML render output size (from render.zig).
pub const html_max = render.send_buf_max;

/// Prefetch cache — flat serialization of all 11 cache slots.
/// Presence flags grouped first (u8 per nullable slot), then data.
/// Nullable slots: 0 = absent, 1 = present. Lists are always present
/// (len field indicates how many items are populated).
pub const PrefetchCache = extern struct {
    // --- Presence flags (28 bytes + 4 reserved = 32) ---
    has_product: u8,
    has_collection: u8,
    has_order: u8,
    has_login_code: u8,
    has_user_by_email: u8,
    has_result: u8,
    has_identity: u8,
    reserved_flags: u8,
    products_presence: [message.order_items_max]u8,
    reserved_presence: [4]u8,

    // --- Data (largest alignment first) ---
    identity: message.PrefetchIdentity,
    product: message.Product,
    collection: message.ProductCollection,
    order: message.OrderResult,
    user_by_email: u128,
    product_list: message.ProductList,
    collection_list: message.CollectionList,
    order_list: message.OrderSummaryList,
    products: [message.order_items_max]message.Product,
    login_code: message.LoginCodeEntry,
    result: u8,
    reserved_data: [15]u8,

    comptime {
        assert(stdx.no_padding(PrefetchCache));
        // Struct alignment is 16 (from u128 fields in Product, etc.)
        assert(@sizeOf(PrefetchCache) % 16 == 0);
    }
};

/// Single write slot — tag identifies the Write union variant,
/// data is padded to the largest variant size (OrderResult).
pub const WriteSlot = extern struct {
    tag: u8,
    reserved_tag: [15]u8,
    data: [@sizeOf(message.OrderResult)]u8,

    comptime {
        assert(stdx.no_padding(WriteSlot));
        assert(@sizeOf(WriteSlot) == 16 + @sizeOf(message.OrderResult));
        assert(@offsetOf(WriteSlot, "data") == 16);
    }
};

/// Execute+render request: Zig → sidecar.
pub const ExecuteRenderRequest = extern struct {
    tag: Tag,
    operation: message.Operation,
    is_sse: u8,
    reserved: [13]u8,
    id: u128,
    body: [message.body_max]u8,
    cache: PrefetchCache,

    comptime {
        assert(stdx.no_padding(ExecuteRenderRequest));
        assert(@sizeOf(ExecuteRenderRequest) % 16 == 0);
    }
};

/// Execute+render response: sidecar → Zig.
pub const ExecuteRenderResponse = extern struct {
    status: message.Status,
    writes_len: u8,
    result_tag: u8,
    reserved: [13]u8,
    result: [@sizeOf(message.PageLoadDashboardResult)]u8,
    writes: [SM.writes_max]WriteSlot,
    html_len: u32,
    html: [html_max]u8,
    // Tail padding: struct alignment is 4 (from html_len u32).
    tail_reserved: [tail_pad]u8,

    // Pre-html fields are all 4-aligned (16-byte header + result + writes + html_len).
    // Tail padding depends only on html_max.
    const tail_pad = (4 - (@as(usize, html_max) % 4)) % 4;

    comptime {
        assert(stdx.no_padding(ExecuteRenderResponse));
        assert(@sizeOf(ExecuteRenderResponse) % 4 == 0);
        assert(SM.writes_max == 21);
    }
};

// Memory budget assertion — both buffers allocated once at startup.
// Single connection, single-threaded server.
comptime {
    const total = @sizeOf(ExecuteRenderRequest) + @sizeOf(ExecuteRenderResponse);
    assert(total < 300 * 1024);
}
