//! Handler prelude — single import for everything a handler needs.
//!
//! Usage: const t = @import("../prelude.zig");
//!
//! Provides framework types, domain types, and utilities so handlers
//! don't need 12 separate imports. This is user space (not framework) —
//! each app defines its own prelude based on its domain types.

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

// --- State machine types (for handle phase) ---
pub const ExecuteResult = sm.StateMachineType(Storage).ExecuteResult;
pub const Write = sm.StateMachineType(Storage).Write;

// --- HTML helpers ---
pub const html = @import("html.zig");
