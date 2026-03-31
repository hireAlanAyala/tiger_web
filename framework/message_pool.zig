//! Pre-allocated pool of reference-counted message buffers.
//!
//! Ported from TigerBeetle's src/message_pool.zig, stripped of VSR
//! types (Header, Command, ProcessType, sector alignment).
//!
//! Messages are allocated once at init and reused via ref/unref.
//! The pool size is fixed — exhaustion is a programming error (assert),
//! not a runtime condition. Size the pool to cover all in-flight uses.
//!
//! Used by the message bus for zero-copy send/recv: the send queue
//! holds *Message pointers, recv reads into a *Message buffer.
//! Consumers ref messages to keep data alive past callbacks.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const stdx = @import("stdx");
const StackType = stdx.StackType;

/// A pool of reference-counted Messages. Memory is allocated once at
/// init and reused. Matches TB's MessagePool pattern.
pub fn MessagePoolType(comptime buf_max: u32) type {
    return struct {
        const Self = @This();

        pub const Message = struct {
            buffer: *[buf_max]u8,
            references: u32 = 0,
            link: FreeList.Link = .{},

            /// Increment the reference count. Returns the same pointer.
            /// Caller must eventually call pool.unref().
            pub fn ref(message: *Message) *Message {
                assert(message.references > 0);
                assert(message.link.next == null);
                message.references += 1;
                return message;
            }
        };

        const FreeList = StackType(Message);

        free_list: FreeList,
        messages_max: u32,
        messages: []Message,
        buffers: [][buf_max]u8,

        pub fn init(
            allocator: mem.Allocator,
            messages_max: u32,
        ) error{OutOfMemory}!Self {
            assert(messages_max > 0);

            const buffers = try allocator.alloc([buf_max]u8, messages_max);
            errdefer allocator.free(buffers);

            const messages = try allocator.alloc(Message, messages_max);
            errdefer allocator.free(messages);

            var free_list = FreeList.init(.{
                .capacity = messages_max,
                .verify_push = false,
            });
            for (messages, buffers) |*message, *buffer| {
                message.* = .{ .buffer = buffer, .link = .{} };
                free_list.push(message);
            }

            return .{
                .free_list = free_list,
                .messages_max = messages_max,
                .messages = messages,
                .buffers = buffers,
            };
        }

        pub fn deinit(pool: *Self, allocator: mem.Allocator) void {
            // All messages must have been returned to the pool.
            assert(pool.free_list.count() == pool.messages_max);
            allocator.free(pool.messages);
            allocator.free(pool.buffers);
            pool.* = undefined;
        }

        /// Get an unused message with a buffer of buf_max bytes.
        /// The returned message has exactly one reference.
        /// Panics if the pool is exhausted — size the pool correctly.
        pub fn get_message(pool: *Self) *Message {
            const message = pool.free_list.pop().?;
            assert(message.link.next == null);
            assert(message.references == 0);
            message.references = 1;
            return message;
        }

        /// Decrement the reference count. When it reaches zero, the
        /// message is returned to the pool for reuse.
        pub fn unref(pool: *Self, message: *Message) void {
            assert(message.link.next == null);
            message.references -= 1;
            if (message.references == 0) {
                if (stdx.verify) {
                    @memset(message.buffer, undefined);
                }
                pool.free_list.push(message);
            }
        }
    };
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "MessagePool: get, ref, unref lifecycle" {
    const Pool = MessagePoolType(64);
    var pool = try Pool.init(testing.allocator, 4);
    defer pool.deinit(testing.allocator);

    // Get a message — references = 1.
    const msg = pool.get_message();
    try testing.expectEqual(@as(u32, 1), msg.references);

    // Write into buffer.
    @memcpy(msg.buffer[0..5], "hello");

    // Ref — references = 2.
    const msg2 = msg.ref();
    try testing.expect(msg == msg2);
    try testing.expectEqual(@as(u32, 2), msg.references);

    // Unref once — references = 1, still alive.
    pool.unref(msg);
    try testing.expectEqual(@as(u32, 1), msg.references);

    // Unref again — references = 0, returned to pool.
    pool.unref(msg);
    // msg is now back in the pool — getting it again should work.
    const msg3 = pool.get_message();
    try testing.expectEqual(@as(u32, 1), msg3.references);
    pool.unref(msg3);
}

test "MessagePool: exhaust and return" {
    const Pool = MessagePoolType(32);
    var pool = try Pool.init(testing.allocator, 2);
    defer pool.deinit(testing.allocator);

    const a = pool.get_message();
    const b = pool.get_message();
    // Pool is now empty — free_list.count == 0.
    try testing.expectEqual(@as(u32, 0), pool.free_list.count());

    // Return both.
    pool.unref(a);
    pool.unref(b);
    try testing.expectEqual(@as(u32, 2), pool.free_list.count());
}
