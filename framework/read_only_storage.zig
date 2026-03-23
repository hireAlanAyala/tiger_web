//! ReadOnlyStorage — compile-time enforcement of the prefetch read-only contract.
//!
//! Wraps a *Storage pointer and exposes only read methods. The framework
//! passes this to handler prefetch functions instead of the raw storage.
//! If a prefetch handler tries to call execute(), put(), delete(), or any
//! write method, it's a compile error — the method doesn't exist on the type.
//!
//! Two read interfaces are forwarded:
//!   1. Typed SQL (query, query_all) — for flat row types, the forward path.
//!   2. Legacy reads (get, list, search, etc.) — for domain extern structs
//!      with length fields and packed flags that can't map directly to SQL
//!      columns. Forwarded conditionally: only if the underlying Storage
//!      has the method.
//!
//! Both are reads. The wrapper's job is to exclude writes, not to force
//! a specific read interface.

const std = @import("std");

/// Return type of a method on Storage, identified by name.
/// Used to declare forwarding methods without naming domain types.
fn ReturnOf(comptime Storage: type, comptime name: []const u8) type {
    return @typeInfo(@TypeOf(@field(Storage, name))).@"fn".return_type.?;
}

/// Compile-time read-only wrapper over a storage backend.
///
/// Handlers receive this as `storage: anytype` — the wrapper is invisible
/// to them as long as they only call read methods. If they try to call
/// execute/put/delete, the compiler rejects it.
pub fn ReadOnlyStorage(comptime Storage: type) type {
    return struct {
        const Self = @This();

        storage: *Storage,

        pub fn init(storage: *Storage) Self {
            return .{ .storage = storage };
        }

        // --- Typed SQL interface ---

        pub fn query(self: Self, comptime T: type, comptime sql: [*:0]const u8, args: anytype) ?T {
            return self.storage.query(T, sql, args);
        }

        pub fn query_all(self: Self, comptime T: type, comptime max: usize, comptime sql: [*:0]const u8, args: anytype) ?@import("stdx.zig").BoundedList(T, max) {
            return self.storage.query_all(T, max, sql, args);
        }

        // --- Legacy read methods ---
        //
        // Forwarded by explicit allowlist. Each method delegates to
        // self.storage with the return type extracted from Storage's
        // fn signature so the framework never names domain types.

        pub const has_get = @hasDecl(Storage, "get");
        pub const has_get_collection = @hasDecl(Storage, "get_collection");
        pub const has_get_order = @hasDecl(Storage, "get_order");
        pub const has_list = @hasDecl(Storage, "list");
        pub const has_list_collections = @hasDecl(Storage, "list_collections");
        pub const has_list_products_in_collection = @hasDecl(Storage, "list_products_in_collection");
        pub const has_list_orders = @hasDecl(Storage, "list_orders");
        pub const has_search = @hasDecl(Storage, "search");
        pub const has_get_login_code = @hasDecl(Storage, "get_login_code");
        pub const has_get_user_by_email = @hasDecl(Storage, "get_user_by_email");

        pub fn get(self: Self, id: u128, out: anytype) if (has_get) ReturnOf(Storage, "get") else noreturn {
            return self.storage.get(id, out);
        }

        pub fn get_collection(self: Self, id: u128, out: anytype) if (has_get_collection) ReturnOf(Storage, "get_collection") else noreturn {
            return self.storage.get_collection(id, out);
        }

        pub fn get_order(self: Self, id: u128, out: anytype) if (has_get_order) ReturnOf(Storage, "get_order") else noreturn {
            return self.storage.get_order(id, out);
        }

        pub fn list(self: Self, out: anytype, out_len: anytype, params: anytype) if (has_list) ReturnOf(Storage, "list") else noreturn {
            return self.storage.list(out, out_len, params);
        }

        pub fn list_collections(self: Self, out: anytype, out_len: anytype, cursor: u128) if (has_list_collections) ReturnOf(Storage, "list_collections") else noreturn {
            return self.storage.list_collections(out, out_len, cursor);
        }

        pub fn list_products_in_collection(self: Self, collection_id: u128, out: anytype, out_len: anytype) if (has_list_products_in_collection) ReturnOf(Storage, "list_products_in_collection") else noreturn {
            return self.storage.list_products_in_collection(collection_id, out, out_len);
        }

        pub fn list_orders(self: Self, out: anytype, out_len: anytype, cursor: u128) if (has_list_orders) ReturnOf(Storage, "list_orders") else noreturn {
            return self.storage.list_orders(out, out_len, cursor);
        }

        pub fn search(self: Self, out: anytype, out_len: anytype, search_query: anytype) if (has_search) ReturnOf(Storage, "search") else noreturn {
            return self.storage.search(out, out_len, search_query);
        }

        pub fn get_login_code(self: Self, email: []const u8, out: anytype) if (has_get_login_code) ReturnOf(Storage, "get_login_code") else noreturn {
            return self.storage.get_login_code(email, out);
        }

        pub fn get_user_by_email(self: Self, email: []const u8, out: anytype) if (has_get_user_by_email) ReturnOf(Storage, "get_user_by_email") else noreturn {
            return self.storage.get_user_by_email(email, out);
        }

        // Write methods (execute, put, update, delete, begin, commit, etc.)
        // are intentionally absent.
    };
}

// =====================================================================
// Tests
// =====================================================================

const assert = std.debug.assert;

const MockStorage = struct {
    value: u32,

    const BoundedList = @import("stdx.zig").BoundedList;
    const Result = enum { ok, not_found, busy };

    fn query(_: *MockStorage, comptime T: type, comptime _: [*:0]const u8, _: anytype) ?T {
        return null;
    }

    fn query_all(_: *MockStorage, comptime T: type, comptime max: usize, comptime _: [*:0]const u8, _: anytype) ?BoundedList(T, max) {
        return .{};
    }

    fn get(_: *MockStorage, _: u128, _: *u32) Result {
        return .ok;
    }

    fn execute(_: *MockStorage, comptime _: [*:0]const u8, _: anytype) bool {
        return true;
    }

    fn put(_: *MockStorage) void {}
    fn delete(_: *MockStorage) void {}
    fn begin(_: *MockStorage) void {}
    fn commit(_: *MockStorage) void {}
};

test "ReadOnlyStorage: typed read methods are accessible" {
    var mock = MockStorage{ .value = 42 };
    const db = ReadOnlyStorage(MockStorage).init(&mock);

    const Row = struct { x: u32 };
    _ = db.query(Row, "SELECT x;", .{});
    _ = db.query_all(Row, 10, "SELECT x;", .{});
}

test "ReadOnlyStorage: legacy get is accessible" {
    var mock = MockStorage{ .value = 42 };
    const db = ReadOnlyStorage(MockStorage).init(&mock);

    var out: u32 = 0;
    const result = db.get(1, &out);
    try std.testing.expectEqual(MockStorage.Result.ok, result);
}

test "ReadOnlyStorage: write methods are absent" {
    const RO = ReadOnlyStorage(MockStorage);

    comptime {
        assert(!@hasDecl(RO, "execute"));
        assert(!@hasDecl(RO, "put"));
        assert(!@hasDecl(RO, "delete"));
        assert(!@hasDecl(RO, "begin"));
        assert(!@hasDecl(RO, "commit"));
    }
}

test "ReadOnlyStorage: legacy methods absent on storage without them" {
    const MinimalStorage = struct {
        fn query(_: *@This(), comptime T: type, comptime _: [*:0]const u8, _: anytype) ?T {
            return null;
        }
        fn query_all(_: *@This(), comptime T: type, comptime max: usize, comptime _: [*:0]const u8, _: anytype) ?@import("stdx.zig").BoundedList(T, max) {
            return .{};
        }
    };

    const RO = ReadOnlyStorage(MinimalStorage);
    comptime {
        assert(!RO.has_get);
        assert(!RO.has_list);
        assert(!RO.has_get_collection);
    }
}
