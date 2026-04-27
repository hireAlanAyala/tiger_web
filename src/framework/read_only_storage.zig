//! ReadOnlyStorage — compile-time enforcement of the prefetch read-only contract.
//!
//! The framework does not define which methods are reads and which are
//! writes. That's the storage type's responsibility. Each storage type
//! exports `pub const ReadView` — a wrapper that exposes only its read
//! methods. The framework uses this for prefetch.
//!
//! This design exists because:
//! - The framework doesn't own the database. The user configures it.
//! - The framework can't enumerate all possible read methods on all
//!   possible databases. An allow-list in the framework would need to
//!   be extended for every new db type.
//! - The storage type knows its own read/write split. It declares it
//!   via ReadView. The framework enforces it via the pipeline.
//!
//! Contract: Storage must export `pub const ReadView` with an `init(*Storage)`
//! constructor. The framework calls `Storage.ReadView.init(storage)` and
//! passes the result to handler prefetch functions.
//!
//! If a handler tries to call a write method during prefetch, it's a
//! compile error — the method doesn't exist on ReadView.

const std = @import("std");

/// Validate that a Storage type has the required ReadView interface.
/// Called at comptime by the SM when the Storage type is first used.
pub fn assertReadView(comptime Storage: type) void {
    if (!@hasDecl(Storage, "ReadView")) {
        @compileError(@typeName(Storage) ++ " must export pub const ReadView — " ++
            "a type exposing only read methods for the prefetch phase. " ++
            "See decisions/storage-ownership.md.");
    }
}

// =====================================================================
// Tests
// =====================================================================

const assert = std.debug.assert;

const MockStorage = struct {
    value: u32,

    pub const ReadView = struct {
        storage: *const MockStorage,

        pub fn init(storage: *MockStorage) ReadView {
            return .{ .storage = storage };
        }

        pub fn get(self: ReadView, id: u32) ?u32 {
            _ = id;
            return self.storage.value;
        }
    };

    pub fn get(self: *MockStorage, id: u32) ?u32 {
        _ = id;
        return self.value;
    }

    pub fn put(self: *MockStorage, val: u32) void {
        self.value = val;
    }
};

test "ReadView: read methods accessible" {
    var mock = MockStorage{ .value = 42 };
    const ro = MockStorage.ReadView.init(&mock);
    try std.testing.expectEqual(@as(?u32, 42), ro.get(1));
}

test "ReadView: write methods absent" {
    comptime {
        assert(!@hasDecl(MockStorage.ReadView, "put"));
        assert(@hasDecl(MockStorage.ReadView, "get"));
    }
}

test "assertReadView: valid storage passes" {
    comptime {
        assertReadView(MockStorage);
    }
}
