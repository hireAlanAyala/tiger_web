//! Handler prelude — single import for everything a handler needs.
//!
//! Usage: const t = @import("../prelude.zig");
//!
//! Provides framework types, domain types, and utilities so handlers
//! don't need 12 separate imports. This is user space (not framework) —
//! each app defines its own prelude based on its domain types.

const std = @import("std");
const fw = @import("tiger_framework");
const message = @import("message.zig");
const sm = @import("state_machine.zig");

// --- Framework ---
pub const http = fw.http;
pub const parse = fw.parse;
pub const stdx = fw.stdx;
pub const effects = fw.effects;
pub const HandlerContext = fw.handler.HandlerContext;
pub const RenderResult = fw.effects.RenderResult;

// --- Domain types ---
pub const Message = message.Message;
pub const MessageResponse = message.MessageResponse;
pub const HandlerResponse = message.HandlerResponse;
pub const Operation = message.Operation;
pub const Status = message.Status;
pub const Identity = message.PrefetchIdentity;
pub const Product = message.Product;
pub const ProductCollection = message.ProductCollection;
pub const OrderRequest = message.OrderRequest;
pub const OrderResult = message.OrderResult;
pub const OrderCompletion = message.OrderCompletion;
pub const OrderSummary = message.OrderSummary;
pub const InventoryTransfer = message.InventoryTransfer;
pub const ListParams = message.ListParams;
pub const SearchQuery = message.SearchQuery;
pub const LoginCodeRequest = message.LoginCodeRequest;
pub const LoginVerification = message.LoginVerification;
pub const Membership = message.Membership;

// --- Constants ---
pub const product_name_max = message.product_name_max;
pub const product_description_max = message.product_description_max;
pub const collection_name_max = message.collection_name_max;
pub const list_max = message.list_max;
pub const order_items_max = message.order_items_max;
pub const payment_ref_max = message.payment_ref_max;
pub const OrderStatus = message.OrderStatus;

// --- Storage ---
pub const Storage = @import("storage.zig").SqliteStorage;
pub const BoundedList = fw.stdx.BoundedList;

// --- Query row types ---
//
// Flat structs shaped by SQL queries, not by the wire format. Field names
// match SQL column names (use AS aliases where they differ). No _len
// companion fields — those are a Zig extern struct concern, not a SQL
// concern. Handlers construct extern structs (Product, etc.) for writes
// by setting fields explicitly.
//
// This separation exists because domain types (Product, ProductCollection)
// are extern structs designed for WAL serialization and byte-wise equality.
// They have _len fields, packed flags, and alignment-driven field order —
// none of which map naturally to SQL columns. Query row types are the
// bridge: one field per SQL column, matched by name.
//
// This is sidecar-language-agnostic: every language maps query results to
// flat types with one field per column. The Zig framework does the same.
//
// NUL-termination pair assertion chain:
//   1. input_valid (state_machine.zig) rejects NUL bytes in text fields.
//   2. read_column (storage.zig) copies text into a zeroed [N]u8 array —
//      bytes after the text are zero.
//   3. Handlers use std.mem.sliceTo(&row.name, 0) to recover the length
//      when constructing extern types for writes.
// This chain is safe IFF step 1 holds. If NUL bytes enter the database
// (external tool, migration bug), sliceTo truncates at the first NUL.
// This is an explicit trust assumption, not an accident.

pub const ProductRow = struct {
    id: u128,
    name: [product_name_max]u8,
    description: [product_description_max]u8,
    price_cents: u32,
    inventory: u32,
    version: u32,
    active: bool,
};

pub const CollectionRow = struct {
    id: u128,
    name: [collection_name_max]u8,
    active: bool,
};

pub const OrderRow = struct {
    id: u128,
    total_cents: u64,
    items_len: u8,
    status: OrderStatus,
    timeout_at: u64,
    payment_ref: [payment_ref_max]u8,
};

pub const OrderItemRow = struct {
    product_id: u128,
    name: [product_name_max]u8,
    quantity: u32,
    price_cents: u32,
    line_total_cents: u64,
};

// --- Row type sync assertions ---
//
// If someone adds a column to the products table, they need to update
// both Product (extern) and ProductRow (query). These comptime checks
// catch drift. Skipped fields are enumerated explicitly per type —
// no convention-based name matching that could accidentally skip a
// real field.

fn has_field(comptime T: type, comptime name: []const u8) bool {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

fn assert_row_covers_extern(
    comptime Row: type,
    comptime Extern: type,
    comptime skip: []const []const u8,
) void {
    for (@typeInfo(Extern).@"struct".fields) |ef| {
        var skipped = false;
        for (skip) |s| {
            if (std.mem.eql(u8, ef.name, s)) {
                skipped = true;
                break;
            }
        }
        if (skipped) continue;
        if (!has_field(Row, ef.name)) {
            @compileError("extern field '" ++ ef.name ++ "' on " ++ @typeName(Extern) ++ " has no corresponding field on " ++ @typeName(Row));
        }
    }
}

comptime {
    // Product: _len fields derived from text, flags mapped to active bool,
    // reserved is padding.
    assert_row_covers_extern(ProductRow, Product, &.{ "name_len", "description_len", "flags" });
    // ProductCollection: same pattern.
    assert_row_covers_extern(CollectionRow, ProductCollection, &.{ "name_len", "flags", "reserved" });
}

// --- Row-to-extern conversions ---
//
// Handlers read flat row types from SQL and construct extern structs for
// writes. These conversions are centralized here so the sliceTo/memcpy
// pattern exists in one place, not scattered across handlers.
//
// The NUL-termination assumption (documented above) is encapsulated here.
// If it ever needs to change, there's one place to fix.

pub fn productFromRow(row: ProductRow) Product {
    var p = std.mem.zeroes(Product);
    p.id = row.id;
    p.price_cents = row.price_cents;
    p.inventory = row.inventory;
    p.version = row.version;
    p.flags = .{ .active = row.active };
    const name = std.mem.sliceTo(&row.name, 0);
    @memcpy(p.name[0..name.len], name);
    p.name_len = @intCast(name.len);
    const desc = std.mem.sliceTo(&row.description, 0);
    @memcpy(p.description[0..desc.len], desc);
    p.description_len = @intCast(desc.len);
    return p;
}

pub fn collectionFromRow(row: CollectionRow) ProductCollection {
    var col = std.mem.zeroes(ProductCollection);
    col.id = row.id;
    col.flags = .{ .active = row.active };
    const name = std.mem.sliceTo(&row.name, 0);
    @memcpy(col.name[0..name.len], name);
    col.name_len = @intCast(name.len);
    return col;
}

// --- State machine types (for handle phase) ---
pub const ExecuteResult = sm.ExecuteResult;
pub const Write = sm.Write;

// --- HTML helpers ---
pub const html = @import("html.zig");
