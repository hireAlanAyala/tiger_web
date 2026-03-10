const std = @import("std");
const assert = std.debug.assert;

/// `maybe` is the dual of `assert`: it signals that a condition is sometimes
/// true and sometimes false, and that's fine. Pure documentation — compiles
/// to a tautology. See TigerBeetle's stdx.maybe().
pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

/// Response status — named results, not generic error buckets.
/// Each business logic failure gets its own variant (TigerBeetle style).
/// schema.zig maps these to HTTP status codes + JSON error strings.
pub const Status = enum(u8) {
    ok = 1,
    not_found = 2,
    storage_error = 4,

    // Business logic errors — one per failure reason.
    insufficient_inventory = 10,
    version_conflict = 11,
};

/// Flat operation enum — encodes entity type AND action in a single tag,
/// following TigerBeetle's pattern. Adding a new entity type means adding
/// new variants here; the compiler forces every switch site to handle them.
pub const Operation = enum(u8) {
    // Products
    create_product = 1,
    get_product = 2,
    list_products = 3,
    update_product = 4,
    delete_product = 5,
    get_product_inventory = 6,

    // Inventory
    transfer_inventory = 13,

    // Orders
    create_order = 14,
    get_order = 15,
    list_orders = 16,

    // Collections
    create_collection = 7,
    get_collection = 8,
    list_collections = 9,
    delete_collection = 10,
    add_collection_member = 11,
    remove_collection_member = 12,

    /// Input event type — what the message body carries for this operation.
    /// Called with comptime operation (via inline dispatch) to resolve types
    /// at compile time, same as TigerBeetle's Operation.EventType().
    pub fn EventType(comptime op: Operation) type {
        return switch (op) {
            .create_product, .update_product => Product,
            .create_collection => ProductCollection,
            .add_collection_member, .remove_collection_member => u128,
            .transfer_inventory => InventoryTransfer,
            .create_order => OrderRequest,
            .list_products,
            .list_collections,
            .list_orders,
            => ListParams,
            .get_product,
            .delete_product,
            .get_product_inventory,
            .get_order,
            .get_collection,
            .delete_collection,
            => void,
        };
    }

    /// Runtime equivalent of EventType — returns the expected Event tag
    /// for this operation. Derived from EventType via inline else so the
    /// mapping is never duplicated. Used by pair assertions to validate
    /// event-to-operation pairing at the consumption boundary.
    pub fn event_tag(op: Operation) std.meta.Tag(Event) {
        return switch (op) {
            inline else => |comptime_op| comptime switch (comptime_op.EventType()) {
                Product => .product,
                ProductCollection => .collection,
                u128 => .member_id,
                InventoryTransfer => .transfer,
                OrderRequest => .order,
                ListParams => .list,
                void => .none,
                else => @compileError("unhandled EventType"),
            },
        };
    }
};

pub const collection_name_max = 128;

/// Fixed-size collection record. A named group of products.
pub const ProductCollection = struct {
    id: u128,
    name: [collection_name_max]u8,
    name_len: u8,

    comptime {
        assert(collection_name_max > 0);
        assert(collection_name_max <= std.math.maxInt(u8));
    }

    pub fn name_slice(self: *const ProductCollection) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Payload for transfer_inventory — move quantity units from source to target.
/// Source ID is msg.id; this struct carries the target and amount.
pub const InventoryTransfer = struct {
    target_id: u128,
    quantity: u32,
};

/// Maximum number of line items in a single order.
pub const order_items_max = 20;

/// A single line item in an order request.
pub const OrderItem = struct {
    product_id: u128,
    quantity: u32,
};

/// Order creation request — variable-length array of line items in a fixed-size struct.
pub const OrderRequest = struct {
    id: u128,
    items: [order_items_max]OrderItem,
    items_len: u8,

    comptime {
        assert(order_items_max > 0);
        assert(order_items_max <= std.math.maxInt(u8));
    }

    pub fn items_slice(self: *const OrderRequest) []const OrderItem {
        return self.items[0..self.items_len];
    }
};

/// A single line item in an order response — includes resolved product info.
pub const OrderResultItem = struct {
    product_id: u128,
    name: [product_name_max]u8,
    name_len: u8,
    quantity: u32,
    price_cents: u32,
    line_total_cents: u64,

    pub fn name_slice(self: *const OrderResultItem) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Order result — returned after successful checkout.
pub const OrderResult = struct {
    id: u128,
    items: [order_items_max]OrderResultItem,
    items_len: u8,
    total_cents: u64,

    pub fn items_slice(self: *const OrderResult) []const OrderResultItem {
        return self.items[0..self.items_len];
    }
};

/// Order summary for list responses — header only, no line items.
pub const OrderSummary = struct {
    id: u128,
    total_cents: u64,
    items_len: u8,
};

pub const OrderSummaryList = struct {
    items: [list_max]OrderSummary,
    len: u32,
};

pub const product_name_max = 128;
pub const product_description_max = 512;

/// Fixed-size product record. All fields are value types — no pointers,
/// no allocations. Stored directly in pre-allocated arrays.
pub const Product = struct {
    id: u128,
    name: [product_name_max]u8,
    name_len: u8,
    description: [product_description_max]u8,
    description_len: u16,
    price_cents: u32,
    inventory: u32,
    version: u32,
    active: bool,

    comptime {
        assert(product_name_max > 0);
        assert(product_name_max <= std.math.maxInt(u8));
        assert(product_description_max > 0);
        assert(product_description_max <= std.math.maxInt(u16));
    }

    pub fn name_slice(self: *const Product) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn description_slice(self: *const Product) []const u8 {
        return self.description[0..self.description_len];
    }
};

/// Parameters for list operations — pagination and filtering.
pub const ListParams = struct {
    cursor: u128 = 0, // 0 = first page
    active_filter: ActiveFilter = .any,
    price_min: u32 = 0, // 0 = no minimum
    price_max: u32 = 0, // 0 = no maximum
    name_prefix: [product_name_max]u8 = [_]u8{0} ** product_name_max,
    name_prefix_len: u8 = 0,

    pub const ActiveFilter = enum(u2) {
        any = 0, // no filter
        active_only = 1,
        inactive_only = 2,
    };

    pub fn name_prefix_slice(self: *const ListParams) []const u8 {
        return self.name_prefix[0..self.name_prefix_len];
    }
};

/// Event payload — tagged union carrying operation-specific input data.
/// The state machine never sees HTTP or JSON — only Message with this Event.
pub const Event = union(enum) {
    product: Product,
    collection: ProductCollection,
    member_id: u128, // product_id for add/remove member
    transfer: InventoryTransfer,
    order: OrderRequest,
    list: ListParams,
    none: void,

    /// Extract the typed event value matching an operation's EventType.
    /// Comptime T selects the union field; the tagged union panics at
    /// runtime if the active field doesn't match. This is the analog of
    /// TigerBeetle's `bytes_as_slice(EventType, raw_bytes)` — type-safe
    /// extraction driven by comptime operation dispatch.
    pub fn unwrap(self: Event, comptime T: type) T {
        const field_name = comptime switch (T) {
            Product => "product",
            ProductCollection => "collection",
            u128 => "member_id",
            InventoryTransfer => "transfer",
            OrderRequest => "order",
            ListParams => "list",
            void => "none",
            else => @compileError("Event.unwrap: unhandled type"),
        };
        return @field(self, field_name);
    }
};

/// Typed message from the schema layer to the state machine.
pub const Message = struct {
    operation: Operation,
    id: u128, // primary entity ID (0 for list/create)
    event: Event,
};

/// Maximum number of items returned in a single list response.
pub const list_max = 50;

pub const ProductList = struct {
    items: [list_max]Product,
    len: u32,
};

/// GET /collections/:id returns the collection and its member products.
pub const CollectionWithProducts = struct {
    collection: ProductCollection,
    products: ProductList,
};

pub const CollectionList = struct {
    items: [list_max]ProductCollection,
    len: u32,
};

comptime {
    assert(list_max > 0);
    assert(list_max <= 1024);
}

/// Result payload — self-describing tagged union for response encoding.
/// The encoder switches on the variant — no external context needed.
pub const Result = union(enum) {
    product: Product,
    product_list: ProductList,
    inventory: u32,
    collection: CollectionWithProducts,
    collection_list: CollectionList,
    order: OrderResult,
    order_list: OrderSummaryList,
    empty: void,
};

/// Response from the state machine back through the schema layer.
pub const MessageResponse = struct {
    status: Status,
    result: Result,

    pub const empty_ok = MessageResponse{
        .status = .ok,
        .result = .{ .empty = {} },
    };

    pub const not_found = MessageResponse{
        .status = .not_found,
        .result = .{ .empty = {} },
    };

    pub const storage_error = MessageResponse{
        .status = .storage_error,
        .result = .{ .empty = {} },
    };
};

// =====================================================================
// Tests
// =====================================================================

test "Product name and description slices" {
    var p = Product{
        .id = 0x0102030405060708090a0b0c0d0e0f10,
        .name = undefined,
        .name_len = 5,
        .description = undefined,
        .description_len = 12,
        .price_cents = 1999,
        .inventory = 10,
        .version = 1,
        .active = true,
    };
    @memcpy(p.name[0..5], "Shirt");
    @memcpy(p.description[0..12], "A nice shirt");
    try std.testing.expectEqualSlices(u8, p.name_slice(), "Shirt");
    try std.testing.expectEqualSlices(u8, p.description_slice(), "A nice shirt");
}

test "Product fixed size constraints" {
    try std.testing.expect(product_name_max == 128);
    try std.testing.expect(product_description_max == 512);
    try std.testing.expect(@sizeOf(Product) > 0);
}

test "MessageResponse convenience constructors" {
    const ok = MessageResponse.empty_ok;
    try std.testing.expectEqual(ok.status, .ok);
    try std.testing.expectEqual(ok.result, .empty);

    const nf = MessageResponse.not_found;
    try std.testing.expectEqual(nf.status, .not_found);
    try std.testing.expectEqual(nf.result, .empty);
}

test "Operation EventType comptime resolution" {
    comptime {
        assert(Operation.EventType(.create_product) == Product);
        assert(Operation.EventType(.get_product) == void);
        assert(Operation.EventType(.list_products) == ListParams);
        assert(Operation.EventType(.create_collection) == ProductCollection);
        assert(Operation.EventType(.add_collection_member) == u128);
        assert(Operation.EventType(.transfer_inventory) == InventoryTransfer);
        assert(Operation.EventType(.create_order) == OrderRequest);
    }
}

test "Operation event_tag derived from EventType" {
    // Runtime function — verify it agrees with EventType for every operation.
    try std.testing.expectEqual(Operation.event_tag(.create_product), .product);
    try std.testing.expectEqual(Operation.event_tag(.update_product), .product);
    try std.testing.expectEqual(Operation.event_tag(.create_collection), .collection);
    try std.testing.expectEqual(Operation.event_tag(.add_collection_member), .member_id);
    try std.testing.expectEqual(Operation.event_tag(.remove_collection_member), .member_id);
    try std.testing.expectEqual(Operation.event_tag(.transfer_inventory), .transfer);
    try std.testing.expectEqual(Operation.event_tag(.create_order), .order);
    try std.testing.expectEqual(Operation.event_tag(.list_products), .list);
    try std.testing.expectEqual(Operation.event_tag(.list_collections), .list);
    try std.testing.expectEqual(Operation.event_tag(.list_orders), .list);
    try std.testing.expectEqual(Operation.event_tag(.get_order), .none);
    try std.testing.expectEqual(Operation.event_tag(.get_product), .none);
    try std.testing.expectEqual(Operation.event_tag(.delete_product), .none);
}
