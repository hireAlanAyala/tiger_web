const std = @import("std");
const assert = std.debug.assert;
const maybe = message.maybe;
const message = @import("message.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.state_machine));

pub const StateMachine = struct {
    /// Maximum number of products.
    pub const product_capacity = 1024;

    pub const ProductEntry = struct {
        product: message.Product,
        occupied: bool,
    };

    const empty_product_entry = ProductEntry{
        .product = undefined,
        .occupied = false,
    };

    products: *[product_capacity]ProductEntry,
    product_count: u32,
    product_next_id: u32,

    comptime {
        assert(product_capacity > 0);
    }

    /// Allocate all storage upfront. No allocation after init.
    pub fn init(allocator: std.mem.Allocator) !StateMachine {
        const products = try allocator.create([product_capacity]ProductEntry);
        @memset(products, empty_product_entry);
        return .{
            .products = products,
            .product_count = 0,
            .product_next_id = 1,
        };
    }

    pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
        allocator.destroy(self.products);
    }

    pub fn reset(self: *StateMachine) void {
        @memset(self.products, empty_product_entry);
        self.product_count = 0;
        self.product_next_id = 1;
    }

    /// Execute an operation. Dispatches on the collection tag, then the operation.
    pub fn execute(self: *StateMachine, msg: message.Message) message.MessageResponse {
        switch (msg.body) {
            .products => |product| {
                switch (msg.operation) {
                    .get => return self.product_get(msg.id),
                    .list => return self.product_list(),
                    .create => return self.product_create(product.?),
                    .update => return self.product_update(msg.id, product.?),
                    .delete => return self.product_delete(msg.id),
                }
            },
        }
    }

    fn product_get(self: *const StateMachine, id: u32) message.MessageResponse {
        assert(id > 0);
        const slot = self.find_product(id);
        maybe(slot != null);
        if (slot) |s| {
            assert(self.products[s].occupied);
            return .{
                .status = .ok,
                .body = .{ .products = .{
                    .product = self.products[s].product,
                    .list = undefined,
                    .list_len = 0,
                } },
            };
        }
        return message.MessageResponse.product_not_found;
    }

    fn product_list(self: *const StateMachine) message.MessageResponse {
        var result = message.MessageResponse{
            .status = .ok,
            .body = .{ .products = .{
                .product = null,
                .list = undefined,
                .list_len = 0,
            } },
        };
        var pr = &result.body.products;
        for (self.products) |*entry| {
            if (!entry.occupied) continue;
            assert(pr.list_len < message.MessageResponse.list_max);
            pr.list[pr.list_len] = entry.product;
            pr.list_len += 1;
        }
        assert(pr.list_len == self.product_count);
        return result;
    }

    fn product_create(self: *StateMachine, product: message.Product) message.MessageResponse {
        assert(product.name_len > 0);
        assert(self.product_count < product_capacity);

        const slot = self.find_free_product_slot() orelse unreachable;
        assert(!self.products[slot].occupied);

        var new_product = product;
        new_product.id = self.product_next_id;
        self.product_next_id += 1;

        self.products[slot] = .{
            .product = new_product,
            .occupied = true,
        };
        self.product_count += 1;

        return .{
            .status = .ok,
            .body = .{ .products = .{
                .product = new_product,
                .list = undefined,
                .list_len = 0,
            } },
        };
    }

    fn product_update(self: *StateMachine, id: u32, product: message.Product) message.MessageResponse {
        assert(id > 0);
        assert(product.name_len > 0);
        const slot = self.find_product(id) orelse return message.MessageResponse.product_not_found;
        assert(self.products[slot].occupied);

        var updated = product;
        updated.id = id;
        self.products[slot].product = updated;

        return .{
            .status = .ok,
            .body = .{ .products = .{
                .product = updated,
                .list = undefined,
                .list_len = 0,
            } },
        };
    }

    fn product_delete(self: *StateMachine, id: u32) message.MessageResponse {
        assert(id > 0);
        const slot = self.find_product(id);
        maybe(slot != null);
        if (slot) |s| {
            assert(self.products[s].occupied);
            assert(self.product_count > 0);
            self.products[s].occupied = false;
            self.product_count -= 1;
            return message.MessageResponse.product_empty_ok;
        }
        return message.MessageResponse.product_not_found;
    }

    fn find_product(self: *const StateMachine, id: u32) ?usize {
        for (self.products, 0..) |*entry, i| {
            if (entry.occupied and entry.product.id == id) return i;
        }
        return null;
    }

    fn find_free_product_slot(self: *const StateMachine) ?usize {
        for (self.products, 0..) |*entry, i| {
            if (!entry.occupied) return i;
        }
        return null;
    }

};

// =====================================================================
// Tests
// =====================================================================

fn make_test_product(name: []const u8, price: u32) message.Product {
    var p = message.Product{
        .id = 0,
        .name = undefined,
        .name_len = @intCast(name.len),
        .description = undefined,
        .description_len = 0,
        .price_cents = price,
        .inventory = 0,
        .active = true,
    };
    @memcpy(p.name[0..name.len], name);
    return p;
}

test "create and get" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const create_resp = sm.execute(.{
        .operation = .create,
        .id = 0,
        .body = .{ .products = make_test_product("Widget", 999) },
    });
    try std.testing.expectEqual(create_resp.status, .ok);
    const created = create_resp.body.products.product.?;
    try std.testing.expectEqual(created.id, 1);
    try std.testing.expectEqualSlices(u8, created.name_slice(), "Widget");
    try std.testing.expectEqual(created.price_cents, 999);

    const get_resp = sm.execute(.{
        .operation = .get,
        .id = 1,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(get_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, get_resp.body.products.product.?.name_slice(), "Widget");
}

test "get missing" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const resp = sm.execute(.{
        .operation = .get,
        .id = 99,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "update" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const create_resp = sm.execute(.{
        .operation = .create,
        .id = 0,
        .body = .{ .products = make_test_product("Old Name", 100) },
    });
    const id = create_resp.body.products.product.?.id;

    const update_resp = sm.execute(.{
        .operation = .update,
        .id = id,
        .body = .{ .products = make_test_product("New Name", 200) },
    });
    try std.testing.expectEqual(update_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, update_resp.body.products.product.?.name_slice(), "New Name");
    try std.testing.expectEqual(update_resp.body.products.product.?.price_cents, 200);
    try std.testing.expectEqual(update_resp.body.products.product.?.id, id);
}

test "delete" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const create_resp = sm.execute(.{
        .operation = .create,
        .id = 0,
        .body = .{ .products = make_test_product("Doomed", 100) },
    });
    const id = create_resp.body.products.product.?.id;

    const del_resp = sm.execute(.{
        .operation = .delete,
        .id = id,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(del_resp.status, .ok);

    const get_resp = sm.execute(.{
        .operation = .get,
        .id = id,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(get_resp.status, .not_found);
}

test "delete missing" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const resp = sm.execute(.{
        .operation = .delete,
        .id = 99,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "list" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    _ = sm.execute(.{ .operation = .create, .id = 0, .body = .{ .products = make_test_product("A", 100) } });
    _ = sm.execute(.{ .operation = .create, .id = 0, .body = .{ .products = make_test_product("B", 200) } });

    const resp = sm.execute(.{
        .operation = .list,
        .id = 0,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.body.products.list_len, 2);
    try std.testing.expectEqualSlices(u8, resp.body.products.list[0].name_slice(), "A");
    try std.testing.expectEqualSlices(u8, resp.body.products.list[1].name_slice(), "B");
}

test "auto-increment IDs" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const r1 = sm.execute(.{ .operation = .create, .id = 0, .body = .{ .products = make_test_product("A", 1) } });
    const r2 = sm.execute(.{ .operation = .create, .id = 0, .body = .{ .products = make_test_product("B", 2) } });
    try std.testing.expectEqual(r1.body.products.product.?.id, 1);
    try std.testing.expectEqual(r2.body.products.product.?.id, 2);
}
