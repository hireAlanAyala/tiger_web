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

// --- Storage ---
pub const Storage = @import("storage.zig").SqliteStorage;
pub const BoundedList = fw.stdx.BoundedList;

// --- State machine types (for handle phase) ---
pub const ExecuteResult = sm.StateMachineType(Storage).ExecuteResult;
pub const Write = sm.StateMachineType(Storage).Write;

// --- HTML helpers ---
pub const html = @import("html.zig");
