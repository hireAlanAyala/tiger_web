const std = @import("std");
const assert = std.debug.assert;

/// `maybe` is the dual of `assert`: it signals that a condition is sometimes
/// true and sometimes false, and that's fine. Pure documentation — compiles
/// to a tautology. See TigerBeetle's stdx.maybe().
pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

pub const Status = enum(u8) {
    ok = 1,
    not_found = 2,
    err = 3,
};

pub const Collection = enum(u8) {
    products = 1,
};

pub const Operation = enum(u8) {
    get = 1,
    list = 2,
    create = 3,
    update = 4,
    delete = 5,
};

pub const product_name_max = 128;
pub const product_description_max = 512;

/// Fixed-size product record. All fields are value types — no pointers,
/// no allocations. Stored directly in pre-allocated arrays.
pub const Product = struct {
    id: u32,
    name: [product_name_max]u8,
    name_len: u8,
    description: [product_description_max]u8,
    description_len: u16,
    price_cents: u32,
    inventory: u32,
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

/// Typed message from the schema layer to the state machine.
/// The state machine never sees HTTP or JSON — only this struct.
/// The body is a tagged union keyed on Collection — adding a new
/// collection adds a variant, and the compiler forces every switch
/// to handle it.
pub const Message = struct {
    operation: Operation,
    id: u32, // 0 for list/create
    body: Body,

    pub const Body = union(Collection) {
        products: ?Product, // populated for create/update, null for get/list/delete
    };
};

/// Response from the state machine back through the schema layer.
pub const MessageResponse = struct {
    status: Status,
    body: Body,

    pub const Body = union(Collection) {
        products: ProductResult,
    };

    /// Maximum number of items returned in a single list response.
    pub const list_max = 50;

    pub const ProductResult = struct {
        product: ?Product, // for get, create, update
        list: [list_max]Product, // for list responses
        list_len: u32,
    };

    comptime {
        assert(list_max > 0);
        assert(list_max <= 1024);
    }

    pub const product_empty_ok = MessageResponse{
        .status = .ok,
        .body = .{ .products = .{ .product = null, .list = undefined, .list_len = 0 } },
    };

    pub const product_not_found = MessageResponse{
        .status = .not_found,
        .body = .{ .products = .{ .product = null, .list = undefined, .list_len = 0 } },
    };
};

// =====================================================================
// Tests
// =====================================================================

test "Product name and description slices" {
    var p = Product{
        .id = 1,
        .name = undefined,
        .name_len = 5,
        .description = undefined,
        .description_len = 12,
        .price_cents = 1999,
        .inventory = 10,
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
    const ok = MessageResponse.product_empty_ok;
    try std.testing.expectEqual(ok.status, .ok);
    try std.testing.expectEqual(ok.body.products.product, null);
    try std.testing.expectEqual(ok.body.products.list_len, 0);

    const nf = MessageResponse.product_not_found;
    try std.testing.expectEqual(nf.status, .not_found);
    try std.testing.expectEqual(nf.body.products.product, null);
    try std.testing.expectEqual(nf.body.products.list_len, 0);
}
