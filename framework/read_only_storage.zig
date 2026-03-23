//! ReadOnlyStorage — compile-time enforcement of the prefetch read-only contract.
//!
//! Wraps a *Storage pointer and exposes only read methods (query, query_all).
//! The framework passes this to handler prefetch functions instead of the raw
//! storage. If a prefetch handler tries to call execute(), put(), delete(), or
//! any write method, it's a compile error — the method doesn't exist on the type.
//!
//! Only the typed SQL interface is forwarded. Handlers define flat row types
//! shaped by their queries and use query()/query_all() exclusively.
//! See docs/plans/storage-boundary.md.

const std = @import("std");

/// Compile-time read-only wrapper over a storage backend.
///
/// Handlers receive this as `storage: anytype` — the wrapper is invisible
/// to them as long as they only call query/query_all. If they try to call
/// execute/put/delete, the compiler rejects it.
pub fn ReadOnlyStorage(comptime Storage: type) type {
    comptime {
        if (!@hasDecl(Storage, "query")) @compileError("Storage missing query()");
        if (!@hasDecl(Storage, "query_all")) @compileError("Storage missing query_all()");
    }

    return struct {
        const Self = @This();

        storage: *Storage,

        pub fn init(storage: *Storage) Self {
            return .{ .storage = storage };
        }

        pub fn query(self: Self, comptime T: type, comptime sql: [*:0]const u8, args: anytype) ?T {
            return self.storage.query(T, sql, args);
        }

        pub fn query_all(self: Self, comptime T: type, comptime max: usize, comptime sql: [*:0]const u8, args: anytype) ?@import("stdx.zig").BoundedList(T, max) {
            return self.storage.query_all(T, max, sql, args);
        }

        // Write methods (execute, put, update, delete, begin, commit)
        // are intentionally absent. Any attempt to call them from a
        // prefetch handler is a compile error.
    };
}

// =====================================================================
// Tests
// =====================================================================

const assert = std.debug.assert;

const MockStorage = struct {
    const BoundedList = @import("stdx.zig").BoundedList;

    fn query(_: *MockStorage, comptime T: type, comptime _: [*:0]const u8, _: anytype) ?T {
        return null;
    }

    fn query_all(_: *MockStorage, comptime T: type, comptime max: usize, comptime _: [*:0]const u8, _: anytype) ?BoundedList(T, max) {
        return .{};
    }

    fn execute(_: *MockStorage, comptime _: [*:0]const u8, _: anytype) bool {
        return true;
    }

    fn put(_: *MockStorage) void {}
    fn begin(_: *MockStorage) void {}
    fn commit(_: *MockStorage) void {}
};

test "ReadOnlyStorage: read methods are accessible" {
    var mock = MockStorage{};
    const db = ReadOnlyStorage(MockStorage).init(&mock);

    const Row = struct { x: u32 };
    _ = db.query(Row, "SELECT x;", .{});
    _ = db.query_all(Row, 10, "SELECT x;", .{});
}

test "ReadOnlyStorage: write methods are absent" {
    const RO = ReadOnlyStorage(MockStorage);
    comptime {
        assert(!@hasDecl(RO, "execute"));
        assert(!@hasDecl(RO, "put"));
        assert(!@hasDecl(RO, "begin"));
        assert(!@hasDecl(RO, "commit"));
    }
}
