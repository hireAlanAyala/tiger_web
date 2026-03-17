const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const cs = @import("checksum.zig");

/// `maybe` is the dual of `assert`: it signals that a condition is sometimes
/// true and sometimes false, and that's fine. Pure documentation — compiles
/// to a tautology. See TigerBeetle's stdx.maybe().
pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

/// Response status — named results, not generic error buckets.
/// Each business logic failure gets its own variant (TigerBeetle style).
/// render.zig maps these to HTML error strings.
pub const Status = enum(u8) {
    ok = 1,
    not_found = 2,
    storage_error = 4,

    // Business logic errors — one per failure reason.
    insufficient_inventory = 10,
    version_conflict = 11,
    order_expired = 12,
    order_not_pending = 13,
};

/// Flat operation enum — encodes entity type AND action in a single tag,
/// following TigerBeetle's pattern. Adding a new entity type means adding
/// new variants here; the compiler forces every switch site to handle them.
pub const Operation = enum(u8) {
    // WAL root entry — deterministic sentinel at op 0.
    // Not a valid application operation. Follows TigerBeetle's .root pattern.
    root = 0,

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
    complete_order = 17,
    cancel_order = 18,
    search_products = 19,

    // Collections
    create_collection = 7,
    get_collection = 8,
    list_collections = 9,
    delete_collection = 10,
    add_collection_member = 11,
    remove_collection_member = 12,

    // Pages
    page_load_dashboard = 20,

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
            .complete_order => OrderCompletion,
            .search_products => SearchQuery,
            .list_products,
            .list_collections,
            .list_orders,
            => ListParams,
            .root,
            .get_product,
            .delete_product,
            .get_product_inventory,
            .get_order,
            .cancel_order,
            .get_collection,
            .delete_collection,
            .page_load_dashboard,
            => void,
        };
    }

    /// Runtime equivalent of EventType — returns the expected EventTag
    /// for this operation. Derived from EventType via inline else so the
    /// mapping is never duplicated. Used by body_as pair assertions to
    /// validate operation-to-body-type pairing at the consumption boundary.
    /// Whether this operation mutates state. Read-only operations and
    /// the root sentinel return false. Used by the server to decide
    /// what enters the WAL, and by the replay tool to validate entries.
    pub fn is_mutation(op: Operation) bool {
        return switch (op) {
            .root,
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

    comptime {
        // Both partitions are non-empty — if either is zero, the
        // classifier is vacuous and something was mis-categorized.
        var mutations: u32 = 0;
        var reads: u32 = 0;
        for (std.enums.values(Operation)) |op| {
            if (op.is_mutation()) mutations += 1 else reads += 1;
        }
        assert(mutations > 0);
        assert(reads > 0);

        // Root is never a mutation — the WAL sentinel must not be
        // replayed as an application operation.
        assert(!Operation.root.is_mutation());
    }

    pub fn event_tag(op: Operation) EventTag {
        return switch (op) {
            inline else => |comptime_op| comptime switch (comptime_op.EventType()) {
                Product => .product,
                ProductCollection => .collection,
                u128 => .member_id,
                InventoryTransfer => .transfer,
                OrderRequest => .order,
                OrderCompletion => .completion,
                SearchQuery => .search,
                ListParams => .list,
                void => .none,
                else => @compileError("unhandled EventType"),
            },
        };
    }
};

pub const product_name_max = 128;
pub const product_description_max = 512;
pub const collection_name_max = 128;

/// Product flags — packed struct matching TigerBeetle's AccountFlags pattern.
/// Each boolean property is a single bit; unused bits are explicit padding.
pub const ProductFlags = packed struct(u8) {
    active: bool = false,
    padding: u7 = 0,

    comptime {
        assert(@sizeOf(ProductFlags) == @sizeOf(u8));
        assert(@bitSizeOf(ProductFlags) == @sizeOf(ProductFlags) * 8);
    }
};

/// Fixed-size product record. All fields are value types — no pointers,
/// no allocations. Stored directly in pre-allocated arrays.
///
/// extern struct with no padding — enables byte-wise equality comparison.
/// Fields ordered largest-to-smallest to avoid implicit alignment gaps.
pub const Product = extern struct {
    id: u128,
    description: [product_description_max]u8,
    name: [product_name_max]u8,
    price_cents: u32,
    inventory: u32,
    version: u32,
    description_len: u16,
    name_len: u8,
    flags: ProductFlags,

    comptime {
        assert(stdx.no_padding(Product));
        assert(@sizeOf(Product) == 672);
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

/// Fixed-size collection record. A named group of products.
pub const ProductCollection = extern struct {
    id: u128,
    name: [collection_name_max]u8,
    name_len: u8,
    reserved: [15]u8,

    comptime {
        assert(stdx.no_padding(ProductCollection));
        assert(@sizeOf(ProductCollection) == 160);
        assert(collection_name_max > 0);
        assert(collection_name_max <= std.math.maxInt(u8));
    }

    pub fn name_slice(self: *const ProductCollection) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Payload for transfer_inventory — move quantity units from source to target.
/// Source ID is msg.id; this struct carries the target and amount.
pub const InventoryTransfer = extern struct {
    target_id: u128,
    quantity: u32,
    reserved: [12]u8,

    comptime {
        assert(stdx.no_padding(InventoryTransfer));
        assert(@sizeOf(InventoryTransfer) == 32);
    }
};

/// Order status — two-phase lifecycle matching TigerBeetle's pending transfers.
pub const OrderStatus = enum(u8) {
    pending = 1,
    confirmed = 2,
    failed = 3,
    cancelled = 4,
};

/// Default timeout for pending orders (seconds).
pub const order_timeout_seconds = 60;

/// Maximum number of line items in a single order.
pub const order_items_max = 20;

/// A single line item in an order request.
pub const OrderItem = extern struct {
    product_id: u128,
    quantity: u32,
    reserved: [12]u8,

    comptime {
        assert(stdx.no_padding(OrderItem));
        assert(@sizeOf(OrderItem) == 32);
    }
};

/// Order creation request — variable-length array of line items in a fixed-size struct.
pub const OrderRequest = extern struct {
    id: u128,
    items: [order_items_max]OrderItem,
    items_len: u8,
    reserved: [15]u8,

    comptime {
        assert(stdx.no_padding(OrderRequest));
        assert(order_items_max > 0);
        assert(order_items_max <= std.math.maxInt(u8));
    }

    pub fn items_slice(self: *const OrderRequest) []const OrderItem {
        return self.items[0..self.items_len];
    }
};

pub const payment_ref_max = 64;

/// Completion event for two-phase orders — the worker posts this after
/// the external API call succeeds or fails. On confirmation, may carry
/// an external payment reference (e.g., Stripe charge ID).
pub const OrderCompletion = extern struct {
    payment_ref: [payment_ref_max]u8,
    result: OrderCompletionResult,
    payment_ref_len: u8,
    reserved: [14]u8,

    pub const OrderCompletionResult = enum(u8) {
        confirmed = 1,
        failed = 2,
    };

    comptime {
        assert(stdx.no_padding(OrderCompletion));
        assert(@sizeOf(OrderCompletion) == 80);
    }

    pub fn payment_ref_slice(self: *const OrderCompletion) []const u8 {
        return self.payment_ref[0..self.payment_ref_len];
    }
};

/// A single line item in an order response — includes resolved product info.
pub const OrderResultItem = extern struct {
    product_id: u128,
    name: [product_name_max]u8,
    line_total_cents: u64,
    price_cents: u32,
    quantity: u32,
    name_len: u8,
    reserved: [15]u8,

    comptime {
        assert(stdx.no_padding(OrderResultItem));
        assert(@sizeOf(OrderResultItem) == 176);
    }

    pub fn name_slice(self: *const OrderResultItem) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Order result — returned after successful checkout.
pub const OrderResult = extern struct {
    id: u128,
    items: [order_items_max]OrderResultItem,
    payment_ref: [payment_ref_max]u8,
    total_cents: u64,
    timeout_at: u64,
    items_len: u8,
    status: OrderStatus,
    payment_ref_len: u8,
    reserved: [13]u8,

    comptime {
        assert(stdx.no_padding(OrderResult));
    }

    pub fn items_slice(self: *const OrderResult) []const OrderResultItem {
        return self.items[0..self.items_len];
    }

    pub fn payment_ref_slice(self: *const OrderResult) []const u8 {
        return self.payment_ref[0..self.payment_ref_len];
    }
};

/// Order summary for list responses — header only, no line items.
pub const OrderSummary = extern struct {
    id: u128,
    payment_ref: [payment_ref_max]u8,
    total_cents: u64,
    timeout_at: u64,
    items_len: u8,
    status: OrderStatus,
    payment_ref_len: u8,
    reserved: [13]u8,

    comptime {
        assert(stdx.no_padding(OrderSummary));
    }

    pub fn payment_ref_slice(self: *const OrderSummary) []const u8 {
        return self.payment_ref[0..self.payment_ref_len];
    }
};

pub const OrderSummaryList = struct {
    items: [list_max]OrderSummary,
    len: u32,
};

pub const search_query_max = 128;

/// Full-text search query for products.
pub const SearchQuery = extern struct {
    query: [search_query_max]u8,
    query_len: u8,
    reserved: [15]u8,

    comptime {
        assert(stdx.no_padding(SearchQuery));
        assert(@sizeOf(SearchQuery) == 144);
        assert(search_query_max > 0);
        assert(search_query_max <= std.math.maxInt(u8));
    }

    pub fn query_slice(self: *const SearchQuery) []const u8 {
        return self.query[0..self.query_len];
    }

    /// Search spec: tokenize query into words (split on whitespace), product
    /// matches if ALL words appear as case-insensitive ASCII substrings in
    /// either name or description. Defined here so both storage backends
    /// use identical semantics.
    pub fn matches(self: *const SearchQuery, product: *const Product) bool {
        const q = self.query[0..self.query_len];
        const name = product.name[0..product.name_len];
        const desc = product.description[0..product.description_len];

        var pos: usize = 0;
        var found_word = false;
        while (pos < q.len) {
            // Skip whitespace.
            if (q[pos] == ' ') {
                pos += 1;
                continue;
            }
            // Find end of word.
            const start = pos;
            while (pos < q.len and q[pos] != ' ') : (pos += 1) {}
            const word = q[start..pos];
            found_word = true;
            // Every word must appear in name or description.
            if (!contains_substr(name, word) and !contains_substr(desc, word)) return false;
        }
        return found_word;
    }

    fn contains_substr(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var match = true;
            for (0..needle.len) |j| {
                if (ascii_lower(haystack[i + j]) != ascii_lower(needle[j])) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn ascii_lower(ch: u8) u8 {
        return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
    }
};

/// Parameters for list operations — pagination and filtering.
pub const ListParams = extern struct {
    cursor: u128,
    name_prefix: [product_name_max]u8,
    price_min: u32,
    price_max: u32,
    name_prefix_len: u8,
    active_filter: ActiveFilter,
    reserved: [6]u8,

    comptime {
        assert(stdx.no_padding(ListParams));
        assert(@sizeOf(ListParams) == 160);
    }

    pub const ActiveFilter = enum(u8) {
        any = 0, // no filter
        active_only = 1,
        inactive_only = 2,
    };

    pub fn name_prefix_slice(self: *const ListParams) []const u8 {
        return self.name_prefix[0..self.name_prefix_len];
    }
};

/// Event tag — identifies which type the message body carries.
/// Standalone enum (not tied to a tagged union) for use with body_as assertions.
pub const EventTag = enum {
    product,
    collection,
    member_id,
    transfer,
    order,
    completion,
    search,
    list,
    none,

    /// Map a comptime type back to its EventTag.
    pub fn from_type(comptime T: type) EventTag {
        return switch (T) {
            Product => .product,
            ProductCollection => .collection,
            u128 => .member_id,
            InventoryTransfer => .transfer,
            OrderRequest => .order,
            OrderCompletion => .completion,
            SearchQuery => .search,
            ListParams => .list,
            else => @compileError("EventTag.from_type: unhandled type"),
        };
    }
};

/// Maximum body size — fits our largest event type (OrderRequest).
/// All EventType sizes are verified at comptime.
pub const body_max = @sizeOf(OrderRequest);

comptime {
    assert(body_max == 672);
    for (std.enums.values(Operation)) |op| {
        if (op.EventType() != void) {
            assert(@sizeOf(op.EventType()) <= body_max);
        }
    }
}

/// Fixed-size message — extern struct with no padding for WAL serialization.
/// The operation field determines the body's type; access through body_as().
///
/// Fields ordered largest-to-smallest alignment to avoid padding gaps.
/// WAL fields (checksum, checksum_body, parent, op, timestamp) are populated
/// by wal.zig at commit time. Zeroed when constructed by codec/fuzz/tests.
pub const Message = extern struct {
    checksum: u128,
    checksum_body: u128,
    parent: u128,
    id: u128,
    user_id: u128,
    op: u64,
    timestamp: i64,
    operation: Operation,
    reserved: [15]u8,
    body: [body_max]u8,

    /// Byte offset where the body begins. Header = [16..body_offset], body = [body_offset..].
    pub const body_offset = @offsetOf(Message, "body");

    comptime {
        assert(stdx.no_padding(Message));
        assert(@sizeOf(Message) == 784);
        assert(body_offset == 112);
    }

    /// Construct a message with a typed event value copied into the body.
    /// Zeroes all fields first — WAL fields default to 0.
    pub fn init(operation: Operation, id: u128, user_id: u128, event: anytype) Message {
        var msg = std.mem.zeroes(Message);
        msg.operation = operation;
        msg.id = id;
        msg.user_id = user_id;
        const T = @TypeOf(event);
        if (T != void) {
            comptime assert(@sizeOf(T) <= body_max);
            @memcpy(msg.body[0..@sizeOf(T)], std.mem.asBytes(&event));
        }
        return msg;
    }

    /// Typed read access to the body region. Returns a pointer into the
    /// message's body — no copy. Runtime assert checks the operation's
    /// event tag matches T (pair assertion with init).
    pub fn body_as(self: *const Message, comptime T: type) *const T {
        comptime {
            assert(@sizeOf(T) > 0);
            assert(@sizeOf(T) <= body_max);
        }
        assert(self.operation.event_tag() == comptime EventTag.from_type(T));
        return @ptrCast(@alignCast(&self.body));
    }

    /// Compute checksum_body over body, then checksum over the header
    /// region only (bytes [16..body_offset]). Follows TigerBeetle's
    /// set_checksum_body() then set_checksum() pattern.
    ///
    /// checksum covers the header (which includes checksum_body), so it
    /// transitively covers the body. But the two checksums are independent:
    /// checksum validates the header, checksum_body validates the body.
    pub fn set_checksum(self: *Message) void {
        self.checksum_body = cs.checksum(&self.body);
        const checksum_size = @sizeOf(@TypeOf(self.checksum));
        self.checksum = cs.checksum(std.mem.asBytes(self)[checksum_size..body_offset]);
    }

    /// Validate header checksum only (bytes [16..body_offset]).
    /// Sufficient for recovery scanning — one Aegis pass over the
    /// header region, not the full entry.
    pub fn valid_checksum_header(self: *const Message) bool {
        const checksum_size = @sizeOf(@TypeOf(self.checksum));
        return self.checksum == cs.checksum(std.mem.asBytes(self)[checksum_size..body_offset]);
    }

    /// Validate body checksum independently.
    pub fn valid_checksum_body(self: *const Message) bool {
        return self.checksum_body == cs.checksum(&self.body);
    }

    /// Validate both checksums. Header first (cheap reject), then body.
    pub fn valid_checksum(self: *const Message) bool {
        return self.valid_checksum_header() and self.valid_checksum_body();
    }
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

/// Maximum items per list in a dashboard page load response.
/// This is a domain constraint: the dashboard shows a summary, not a dump.
/// Buffer sizing in render.zig derives from this constant, not list_max.
pub const dashboard_list_max = 10;

comptime {
    assert(list_max > 0);
    assert(list_max <= 1024);
    assert(dashboard_list_max > 0);
    assert(dashboard_list_max <= list_max);
}

/// Dashboard page load result — all three lists in one response.
/// Each list is capped to dashboard_list_max by the state machine.
pub const PageLoadDashboardResult = struct {
    products: ProductList,
    collections: CollectionList,
    orders: OrderSummaryList,

    comptime {
        // The state machine must cap lists before constructing this result.
        // render.zig derives its buffer math from dashboard_list_max, not list_max.
        // If this assert is wrong, fix the state machine — not the buffer.
        assert(dashboard_list_max <= list_max);
    }
};

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
    page_load_dashboard: PageLoadDashboardResult,
    empty: void,
};

/// Response from the state machine back through the codec layer.
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
    var p = std.mem.zeroes(Product);
    p.id = 0x0102030405060708090a0b0c0d0e0f10;
    p.name_len = 5;
    p.description_len = 12;
    p.price_cents = 1999;
    p.inventory = 10;
    p.version = 1;
    p.flags = .{ .active = true };
    @memcpy(p.name[0..5], "Shirt");
    @memcpy(p.description[0..12], "A nice shirt");
    try std.testing.expectEqualSlices(u8, p.name_slice(), "Shirt");
    try std.testing.expectEqualSlices(u8, p.description_slice(), "A nice shirt");
}

test "Product fixed size constraints" {
    try std.testing.expect(product_name_max == 128);
    try std.testing.expect(product_description_max == 512);
    try std.testing.expectEqual(@sizeOf(Product), 672);
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
    // EventTag is a standalone enum; event_tag derives from EventType at comptime.
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

test "Message extern struct layout" {
    comptime {
        assert(stdx.no_padding(Message));
        assert(@sizeOf(Message) == 784);
    }
}

test "Message.init and body_as roundtrip" {
    const p = std.mem.zeroes(Product);
    const msg = Message.init(.create_product, 42, 7, p);
    try std.testing.expectEqual(msg.operation, .create_product);
    try std.testing.expectEqual(msg.id, 42);
    try std.testing.expectEqual(msg.user_id, 7);
    try std.testing.expectEqual(msg.body_as(Product).id, 0);
}

test "Message.init void event" {
    const msg = Message.init(.get_product, 42, 7, {});
    try std.testing.expectEqual(msg.operation, .get_product);
    try std.testing.expectEqual(msg.id, 42);
    try std.testing.expect(stdx.zeroed(&msg.body));
}

test "extern struct byte-wise equality" {
    const a = std.mem.zeroes(Product);
    var b = std.mem.zeroes(Product);
    try std.testing.expect(stdx.equal_bytes(Product, &a, &b));
    b.price_cents = 1;
    try std.testing.expect(!stdx.equal_bytes(Product, &a, &b));
}
