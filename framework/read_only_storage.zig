//! ReadOnlyStorage — compile-time enforcement of the prefetch read-only contract.
//!
//! Wraps a *Storage pointer and exposes only read methods. The framework
//! passes this to handler prefetch functions instead of the raw storage.
//! If a prefetch handler tries to call execute(), put(), delete(), or any
//! write method, it's a compile error — the method doesn't exist on the type.
//!
//! Only the typed SQL interface (query, query_all) is forwarded. Legacy
//! prepared-statement methods (get, list, etc.) are not — handlers must
//! migrate to the typed interface before being wired into the new pipeline.
//! This is intentional: two read interfaces at the same trust level is
//! unnecessary complexity. The typed interface is the forward path.

/// Compile-time read-only wrapper over a storage backend.
///
/// Handlers receive this as `storage: anytype` — the wrapper is invisible
/// to them as long as they only call query/query_all. If they try to call
/// execute/put/delete, the compiler rejects it.
pub fn ReadOnlyStorage(comptime Storage: type) type {
    comptime {
        // The underlying storage must support the typed SQL interface.
        if (!@hasDecl(Storage, "query")) @compileError("Storage missing query() — required for ReadOnlyStorage");
        if (!@hasDecl(Storage, "query_all")) @compileError("Storage missing query_all() — required for ReadOnlyStorage");
    }

    return struct {
        const Self = @This();

        storage: *Storage,

        pub fn init(storage: *Storage) Self {
            return .{ .storage = storage };
        }

        /// Query a single row. Returns null if not found or on step error.
        pub fn query(self: Self, comptime T: type, comptime sql: [*:0]const u8, args: anytype) ?T {
            return self.storage.query(T, sql, args);
        }

        /// Query multiple rows into a bounded array. Returns null on step error.
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

const std = @import("std");
const assert = std.debug.assert;

/// Minimal mock storage for testing. Has both read and write methods.
const MockStorage = struct {
    value: u32,

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
    fn delete(_: *MockStorage) void {}
    fn begin(_: *MockStorage) void {}
    fn commit(_: *MockStorage) void {}
};

test "ReadOnlyStorage: read methods are accessible" {
    var mock = MockStorage{ .value = 42 };
    const db = ReadOnlyStorage(MockStorage).init(&mock);

    const Row = struct { x: u32 };
    _ = db.query(Row, "SELECT x;", .{});
    _ = db.query_all(Row, 10, "SELECT x;", .{});
}

test "ReadOnlyStorage: write methods are absent" {
    const RO = ReadOnlyStorage(MockStorage);

    // These must all be false — write methods are not forwarded.
    comptime {
        assert(!@hasDecl(RO, "execute"));
        assert(!@hasDecl(RO, "put"));
        assert(!@hasDecl(RO, "delete"));
        assert(!@hasDecl(RO, "begin"));
        assert(!@hasDecl(RO, "commit"));
    }
}

test "ReadOnlyStorage: underlying storage still has write methods" {
    // Sanity: the mock has write methods, the wrapper strips them.
    comptime {
        assert(@hasDecl(MockStorage, "execute"));
        assert(@hasDecl(MockStorage, "put"));
        assert(@hasDecl(MockStorage, "delete"));
        assert(@hasDecl(MockStorage, "begin"));
        assert(@hasDecl(MockStorage, "commit"));
    }
}
