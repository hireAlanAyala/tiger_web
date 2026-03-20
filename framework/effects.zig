const std = @import("std");
const assert = std.debug.assert;

/// Render effects — a list of UI instructions returned by handler render functions.
///
/// The handler always returns effects. The framework delivers them based on
/// whether a page exists in the browser:
/// - Page exists (Datastar header) → send as SSE events
/// - No page yet (first navigation) → apply to page template, send as HTML
///
/// Effect types align 1:1 with Datastar SSE events.
/// Effects are small structs with offset/length pairs into a shared buffer
/// owned by the connection — same pattern as Message.body. No large inline
/// arrays, no stack monsters.

pub const effects_max = 16;
pub const selector_max = 64;

comptime {
    assert(effects_max > 0);
    assert(selector_max > 0);
}

pub const PatchMode = enum {
    outer,
    inner,
    replace,
    prepend,
    append,
    before,
    after,
    remove,
};

pub const EffectKind = enum {
    /// Morph/append/replace/remove DOM elements.
    /// Maps to `datastar-patch-elements`.
    patch,

    /// Update reactive signal state on the client.
    /// Maps to `datastar-patch-signals`.
    signal,

    /// Execute JS in the browser.
    /// Maps to `datastar-patch-elements` with script tag.
    script,

    /// Re-run another page's prefetch → render, push to SSE subscribers.
    /// Framework-level — no direct Datastar event.
    sync,
};

/// Small descriptor — points into the shared buffer. No inline data.
pub const Effect = struct {
    kind: EffectKind,
    mode: PatchMode = .outer,
    target: [selector_max]u8 = .{0} ** selector_max,
    target_len: u8 = 0,
    /// Offset and length into the shared buffer for HTML/script/signal content.
    content_offset: u32 = 0,
    content_len: u32 = 0,

    pub fn target_slice(self: *const Effect) []const u8 {
        return self.target[0..self.target_len];
    }

    pub fn content(self: *const Effect, buf: []const u8) []const u8 {
        // Pair assertion: written by add_*, read here. Offset+len must be in bounds.
        assert(self.content_offset + self.content_len <= buf.len);
        return buf[self.content_offset..][0..self.content_len];
    }
};

/// Render effects list. The `buf` is borrowed from the connection's send buffer.
/// Handler writes HTML content into it via add_* methods. Effects store offsets.
pub const RenderEffects = struct {
    effects: [effects_max]Effect = undefined,
    len: u8 = 0,
    buf: []u8,
    buf_pos: u32 = 0,

    pub fn init(buf: []u8) RenderEffects {
        assert(buf.len > 0);
        return .{ .buf = buf };
    }

    pub fn add_patch(self: *RenderEffects, target: []const u8, html: []const u8, mode: PatchMode) void {
        assert(self.len < effects_max);
        assert(target.len > 0);
        assert(target.len <= selector_max);
        if (mode == .remove) {
            assert(html.len == 0); // remove deletes elements, doesn't insert
        } else {
            assert(html.len > 0);
        }
        var effect = Effect{
            .kind = .patch,
            .mode = mode,
            .content_offset = self.buf_pos,
            .content_len = @intCast(html.len),
        };
        @memcpy(effect.target[0..target.len], target);
        effect.target_len = @intCast(target.len);
        self.write_content(html);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn add_signal(self: *RenderEffects, signals_json: []const u8) void {
        assert(self.len < effects_max);
        assert(signals_json.len > 0);
        const effect = Effect{
            .kind = .signal,
            .content_offset = self.buf_pos,
            .content_len = @intCast(signals_json.len),
        };
        self.write_content(signals_json);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn add_script(self: *RenderEffects, script: []const u8) void {
        assert(self.len < effects_max);
        assert(script.len > 0);
        const effect = Effect{
            .kind = .script,
            .content_offset = self.buf_pos,
            .content_len = @intCast(script.len),
        };
        self.write_content(script);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn add_sync(self: *RenderEffects, route: []const u8) void {
        assert(self.len < effects_max);
        assert(route.len > 0);
        assert(route[0] == '/'); // routes must be absolute paths
        assert(route.len <= selector_max);
        var effect = Effect{ .kind = .sync };
        @memcpy(effect.target[0..route.len], route);
        effect.target_len = @intCast(route.len);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn slice(self: *const RenderEffects) []const Effect {
        const s = self.effects[0..self.len];
        for (s) |e| {
            // Sync effects are target-only — no content.
            if (e.kind == .sync) assert(e.content_len == 0);
        }
        return s;
    }

    fn write_content(self: *RenderEffects, data: []const u8) void {
        const new_pos = self.buf_pos + @as(u32, @intCast(data.len));
        assert(new_pos >= self.buf_pos); // no overflow
        assert(new_pos <= self.buf.len);
        @memcpy(self.buf[self.buf_pos..][0..data.len], data);
        self.buf_pos = new_pos;
    }
};

// =====================================================================
// Tests
// =====================================================================

test "render effects basic" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_patch("#toast", "hello", .append);
    fx.add_sync("/dashboard");

    try std.testing.expectEqual(@as(u8, 2), fx.len);
    try std.testing.expectEqual(EffectKind.patch, fx.effects[0].kind);
    try std.testing.expectEqual(PatchMode.append, fx.effects[0].mode);
    try std.testing.expect(std.mem.eql(u8, "#toast", fx.effects[0].target_slice()));
    try std.testing.expect(std.mem.eql(u8, "hello", fx.effects[0].content(&buf)));
    try std.testing.expectEqual(EffectKind.sync, fx.effects[1].kind);
    try std.testing.expect(std.mem.eql(u8, "/dashboard", fx.effects[1].target_slice()));
}

test "render effects script" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_script("window.location.href='/'");

    try std.testing.expectEqual(@as(u8, 1), fx.len);
    try std.testing.expectEqual(EffectKind.script, fx.effects[0].kind);
    try std.testing.expect(std.mem.eql(u8, "window.location.href='/'", fx.effects[0].content(&buf)));
}

test "render effects signal" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_signal("{\"cartCount\":5}");

    try std.testing.expectEqual(@as(u8, 1), fx.len);
    try std.testing.expectEqual(EffectKind.signal, fx.effects[0].kind);
    try std.testing.expect(std.mem.eql(u8, "{\"cartCount\":5}", fx.effects[0].content(&buf)));
}

test "render effects empty" {
    var buf: [4096]u8 = undefined;
    const fx = RenderEffects.init(&buf);
    try std.testing.expectEqual(@as(u8, 0), fx.len);
    try std.testing.expectEqual(@as(usize, 0), fx.slice().len);
}

test "render effects fill to capacity" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    var i: u8 = 0;
    while (i < effects_max) : (i += 1) {
        fx.add_patch("#x", "y", .outer);
    }
    try std.testing.expectEqual(effects_max, fx.len);
    // All effects retrievable with correct content.
    for (fx.slice()) |e| {
        try std.testing.expect(std.mem.eql(u8, "y", e.content(&buf)));
        try std.testing.expect(std.mem.eql(u8, "#x", e.target_slice()));
    }
}

test "render effects fill buffer to exact capacity" {
    // Buffer exactly fits the content — no room to spare.
    var buf: [5]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_patch("#a", "hello", .outer); // 5 bytes fills buffer exactly
    try std.testing.expectEqual(@as(u32, 5), fx.buf_pos);
    try std.testing.expect(std.mem.eql(u8, "hello", fx.effects[0].content(&buf)));
}

test "render effects mixed types" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_patch("#list", "<div>items</div>", .inner);
    fx.add_signal("{\"count\":3}");
    fx.add_script("console.log('done')");
    fx.add_sync("/dashboard");

    try std.testing.expectEqual(@as(u8, 4), fx.len);
    const s = fx.slice();
    try std.testing.expectEqual(EffectKind.patch, s[0].kind);
    try std.testing.expectEqual(EffectKind.signal, s[1].kind);
    try std.testing.expectEqual(EffectKind.script, s[2].kind);
    try std.testing.expectEqual(EffectKind.sync, s[3].kind);

    // Content offsets are contiguous, non-overlapping.
    try std.testing.expect(s[1].content_offset == s[0].content_offset + s[0].content_len);
    try std.testing.expect(s[2].content_offset == s[1].content_offset + s[1].content_len);
    // Sync has no content.
    try std.testing.expectEqual(@as(u32, 0), s[3].content_len);
}

test "render effects remove mode no html" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_patch("#old-element", "", .remove);
    try std.testing.expectEqual(@as(u8, 1), fx.len);
    try std.testing.expectEqual(PatchMode.remove, fx.effects[0].mode);
    try std.testing.expectEqual(@as(u32, 0), fx.effects[0].content_len);
}

test "render effects sync shortest route" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_sync("/");
    try std.testing.expectEqual(@as(u8, 1), fx.len);
    try std.testing.expect(std.mem.eql(u8, "/", fx.effects[0].target_slice()));
}

test "render effects multiple patches share buffer" {
    var buf: [4096]u8 = undefined;
    var fx = RenderEffects.init(&buf);
    fx.add_patch("#a", "first", .outer);
    fx.add_patch("#b", "second", .inner);

    try std.testing.expectEqual(@as(u8, 2), fx.len);
    try std.testing.expect(std.mem.eql(u8, "first", fx.effects[0].content(&buf)));
    try std.testing.expect(std.mem.eql(u8, "second", fx.effects[1].content(&buf)));
    // Content is contiguous in buffer.
    try std.testing.expectEqual(@as(u32, 0), fx.effects[0].content_offset);
    try std.testing.expectEqual(@as(u32, 5), fx.effects[1].content_offset);
}
