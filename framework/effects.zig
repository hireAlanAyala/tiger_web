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
/// Fixed-size, no allocations — same pattern as ExecuteResult with bounded writes.

pub const effects_max = 16;
pub const selector_max = 64;
pub const html_max = 32 * 1024;

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

pub const Effect = struct {
    kind: EffectKind,

    // Target selector (for patch/signal) or route (for sync).
    target: [selector_max]u8 = .{0} ** selector_max,
    target_len: u8 = 0,

    // HTML content (for patch) or script (for script) or signal JSON (for signal).
    html: [html_max]u8 = .{0} ** html_max,
    html_len: u16 = 0,

    // Patch mode (only for patch effects).
    mode: PatchMode = .outer,

    pub fn target_slice(self: *const Effect) []const u8 {
        return self.target[0..self.target_len];
    }

    pub fn html_slice(self: *const Effect) []const u8 {
        return self.html[0..self.html_len];
    }
};

pub const RenderEffects = struct {
    effects: [effects_max]Effect = undefined,
    len: u8 = 0,

    pub fn add_patch(self: *RenderEffects, target: []const u8, html: []const u8, mode: PatchMode) void {
        assert(self.len < effects_max);
        assert(target.len <= selector_max);
        assert(html.len <= html_max);
        var effect = Effect{ .kind = .patch, .mode = mode };
        @memcpy(effect.target[0..target.len], target);
        effect.target_len = @intCast(target.len);
        @memcpy(effect.html[0..html.len], html);
        effect.html_len = @intCast(html.len);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn add_signal(self: *RenderEffects, signals_json: []const u8) void {
        assert(self.len < effects_max);
        assert(signals_json.len <= html_max);
        var effect = Effect{ .kind = .signal };
        @memcpy(effect.html[0..signals_json.len], signals_json);
        effect.html_len = @intCast(signals_json.len);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn add_script(self: *RenderEffects, script: []const u8) void {
        assert(self.len < effects_max);
        assert(script.len <= html_max);
        var effect = Effect{ .kind = .script };
        @memcpy(effect.html[0..script.len], script);
        effect.html_len = @intCast(script.len);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn add_sync(self: *RenderEffects, route: []const u8) void {
        assert(self.len < effects_max);
        assert(route.len <= selector_max);
        var effect = Effect{ .kind = .sync };
        @memcpy(effect.target[0..route.len], route);
        effect.target_len = @intCast(route.len);
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn slice(self: *const RenderEffects) []const Effect {
        return self.effects[0..self.len];
    }
};

/// Helper to build RenderEffects from handler render functions.
/// Usage: var fx = render(); fx.patch("#list", html, .inner); return fx;
pub fn render() RenderEffects {
    return .{};
}

// =====================================================================
// Tests
// =====================================================================

test "render effects basic" {
    var fx = render();
    fx.add_patch("#toast", "hello", .append);
    fx.add_sync("/dashboard");

    try std.testing.expectEqual(@as(u8, 2), fx.len);
    try std.testing.expectEqual(EffectKind.patch, fx.effects[0].kind);
    try std.testing.expectEqual(PatchMode.append, fx.effects[0].mode);
    try std.testing.expect(std.mem.eql(u8, "#toast", fx.effects[0].target_slice()));
    try std.testing.expect(std.mem.eql(u8, "hello", fx.effects[0].html_slice()));
    try std.testing.expectEqual(EffectKind.sync, fx.effects[1].kind);
    try std.testing.expect(std.mem.eql(u8, "/dashboard", fx.effects[1].target_slice()));
}

test "render effects script" {
    var fx = render();
    fx.add_script("window.location.href='/'");

    try std.testing.expectEqual(@as(u8, 1), fx.len);
    try std.testing.expectEqual(EffectKind.script, fx.effects[0].kind);
    try std.testing.expect(std.mem.eql(u8, "window.location.href='/'", fx.effects[0].html_slice()));
}

test "render effects signal" {
    var fx = render();
    fx.add_signal("{\"cartCount\":5}");

    try std.testing.expectEqual(@as(u8, 1), fx.len);
    try std.testing.expectEqual(EffectKind.signal, fx.effects[0].kind);
    try std.testing.expect(std.mem.eql(u8, "{\"cartCount\":5}", fx.effects[0].html_slice()));
}

test "render effects empty" {
    const fx = render();
    try std.testing.expectEqual(@as(u8, 0), fx.len);
    try std.testing.expectEqual(@as(usize, 0), fx.slice().len);
}
