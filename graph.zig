const std = @import("std");
const Tokenizer = std.zig.Tokenizer;
const Token = std.zig.Token;
const Allocator = std.mem.Allocator;

const NodeKey = struct {
    file: []const u8,
    func: []const u8,

    fn dotId(self: NodeKey, buf: []u8) []const u8 {
        var pos: usize = 0;
        @memcpy(buf[pos..][0..self.file.len], self.file);
        pos += self.file.len;
        buf[pos] = ':';
        pos += 1;
        @memcpy(buf[pos..][0..self.func.len], self.func);
        pos += self.func.len;
        return buf[0..pos];
    }

    fn key(self: NodeKey, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ self.file, self.func });
    }
};

const Edge = struct {
    from: NodeKey,
    to: NodeKey,
};

const FnScope = struct {
    name: []const u8,
    depth: u32,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var arena_impl = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Parse args.
    var json_mode = false;
    var proc_args = std.process.args();
    _ = proc_args.skip();
    while (proc_args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json_mode = true;
    }

    // Discover .zig source files.
    var filenames = std.ArrayList([]const u8).init(arena);
    {
        var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            if (std.mem.eql(u8, entry.name, "graph.zig")) continue;
            if (std.mem.eql(u8, entry.name, "build.zig")) continue;
            try filenames.append(try arena.dupe(u8, entry.name));
        }
    }

    // First pass: collect import maps and all declared function names per file.
    var import_maps = std.StringHashMap(std.StringHashMap([]const u8)).init(arena);
    var sources = std.StringHashMap([:0]const u8).init(arena);
    var global_fns = std.StringHashMap([]const u8).init(arena);

    for (filenames.items) |filename| {
        const source = try std.fs.cwd().readFileAllocOptions(
            arena, filename, 1 << 20, null, @alignOf(u8), 0,
        );
        try sources.put(filename, source);
        try import_maps.put(filename, try extractImports(arena, source));
        try collectFnNames(arena, source, filename, &global_fns);
    }

    // Second pass: extract edges.
    var raw_edges = std.ArrayList(Edge).init(arena);
    for (filenames.items) |filename| {
        const source = sources.get(filename).?;
        const imports = import_maps.getPtr(filename).?;
        try extractEdges(arena, filename, source, imports, &global_fns, &raw_edges);
    }

    // Deduplicate edges.
    var edge_set = std.StringHashMap(void).init(arena);
    var edges = std.ArrayList(Edge).init(arena);
    for (raw_edges.items) |edge| {
        const ek = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}\x00{s}", .{
            edge.from.file, edge.from.func, edge.to.file, edge.to.func,
        });
        if (!edge_set.contains(ek)) {
            try edge_set.put(ek, {});
            try edges.append(edge);
        }
    }

    const stdout = std.io.getStdOut().writer();

    if (json_mode) {
        try outputJson(stdout, arena, edges.items);
    } else {
        try outputDot(stdout, arena, edges.items);
    }
}

fn outputJson(stdout: anytype, arena: Allocator, edges: []const Edge) !void {
    // Collect all unique nodes.
    var node_set = std.StringHashMap(NodeKey).init(arena);
    for (edges) |edge| {
        const fk = try edge.from.key(arena);
        if (!node_set.contains(fk)) try node_set.put(fk, edge.from);
        const tk = try edge.to.key(arena);
        if (!node_set.contains(tk)) try node_set.put(tk, edge.to);
    }

    try stdout.writeAll("{\"nodes\":[");
    var first_node = true;
    var nit = node_set.iterator();
    while (nit.next()) |entry| {
        const nk = entry.value_ptr.*;
        if (!first_node) try stdout.writeAll(",");
        first_node = false;
        try stdout.print("{{\"id\":\"{s}:{s}\",\"file\":\"{s}\",\"func\":\"{s}\"}}", .{
            nk.file, nk.func, nk.file, nk.func,
        });
    }

    try stdout.writeAll("],\"edges\":[");
    for (edges, 0..) |edge, i| {
        if (i > 0) try stdout.writeAll(",");
        try stdout.print("{{\"source\":\"{s}:{s}\",\"target\":\"{s}:{s}\"}}", .{
            edge.from.file, edge.from.func, edge.to.file, edge.to.func,
        });
    }
    try stdout.writeAll("]}\n");
}

fn outputDot(stdout: anytype, arena: Allocator, edges: []const Edge) !void {
    // BFS from main.zig:main.
    var reachable = std.StringHashMap(NodeKey).init(arena);
    var queue = std.ArrayList([]const u8).init(arena);
    const start_key = try (NodeKey{ .file = "main.zig", .func = "main" }).key(arena);
    try reachable.put(start_key, .{ .file = "main.zig", .func = "main" });
    try queue.append(start_key);

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        for (edges) |edge| {
            const from_key = try edge.from.key(arena);
            if (!std.mem.eql(u8, from_key, current)) continue;
            const to_key = try edge.to.key(arena);
            if (reachable.contains(to_key)) continue;
            try reachable.put(to_key, edge.to);
            try queue.append(to_key);
        }
    }

    try stdout.writeAll("digraph {\n");
    try stdout.writeAll("  rankdir=LR;\n");
    try stdout.writeAll("  bgcolor=\"#0d1117\";\n");
    try stdout.writeAll("  node [shape=circle, width=0.2, style=filled, fontcolor=\"#c9d1d9\", fontsize=8, fontname=\"monospace\"];\n");
    try stdout.writeAll("  edge [color=\"#30363d\", arrowsize=0.4];\n");
    try stdout.writeAll("  overlap=false;\n  splines=true;\n");

    var file_nodes = std.StringHashMap(std.ArrayList(NodeKey)).init(arena);
    var rit = reachable.iterator();
    while (rit.next()) |entry| {
        const nk = entry.value_ptr.*;
        const gop = try file_nodes.getOrPut(nk.file);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(NodeKey).init(arena);
        try gop.value_ptr.append(nk);
    }

    var fit = file_nodes.iterator();
    var cluster_idx: u32 = 0;
    while (fit.next()) |entry| {
        const file = entry.key_ptr.*;
        const nodes = entry.value_ptr.items;
        const color = fileColor(file);
        try stdout.print("  subgraph cluster_{d} {{\n", .{cluster_idx});
        try stdout.print("    label=\"{s}\";\n    fontcolor=\"{s}\";\n", .{ file, color });
        try stdout.writeAll("    fontsize=10;\n    fontname=\"monospace\";\n");
        try stdout.print("    color=\"{s}\";\n    style=dashed;\n", .{color});
        for (nodes) |nk| {
            var key_buf: [512]u8 = undefined;
            const dot_id = nk.dotId(&key_buf);
            try stdout.print("    \"{s}\" [label=\"{s}\", fillcolor=\"{s}\", color=\"{s}\"];\n", .{
                dot_id, nk.func, color, color,
            });
        }
        try stdout.writeAll("  }\n");
        cluster_idx += 1;
    }

    for (edges) |edge| {
        const from_key = try edge.from.key(arena);
        const to_key = try edge.to.key(arena);
        if (!reachable.contains(from_key)) continue;
        if (!reachable.contains(to_key)) continue;
        var key_buf: [512]u8 = undefined;
        const from_dot = edge.from.dotId(&key_buf);
        var key_buf2: [512]u8 = undefined;
        const to_dot = edge.to.dotId(&key_buf2);
        const ecolor = if (std.mem.eql(u8, edge.from.file, edge.to.file))
            "#30363d"
        else
            "#58a6ff88";
        try stdout.print("  \"{s}\" -> \"{s}\" [color=\"{s}\"];\n", .{ from_dot, to_dot, ecolor });
    }

    try stdout.writeAll("}\n");
}

fn fileColor(filename: []const u8) []const u8 {
    if (std.mem.eql(u8, filename, "main.zig")) return "#f0883e";
    if (std.mem.eql(u8, filename, "server.zig")) return "#58a6ff";
    if (std.mem.eql(u8, filename, "connection.zig")) return "#79c0ff";
    if (std.mem.eql(u8, filename, "http.zig")) return "#7ee787";
    if (std.mem.eql(u8, filename, "codec.zig")) return "#d2a8ff";
    if (std.mem.eql(u8, filename, "state_machine.zig")) return "#ff7b72";
    if (std.mem.eql(u8, filename, "storage.zig")) return "#ffa657";
    if (std.mem.eql(u8, filename, "io.zig")) return "#56d4dd";
    if (std.mem.eql(u8, filename, "auth.zig")) return "#da3633";
    if (std.mem.eql(u8, filename, "message.zig")) return "#bc8cff";
    if (std.mem.eql(u8, filename, "tracer.zig")) return "#8b949e";
    if (std.mem.eql(u8, filename, "time.zig")) return "#a5d6ff";
    if (std.mem.eql(u8, filename, "marks.zig")) return "#8b949e";
    return "#484f58";
}

fn collectFnNames(arena: Allocator, source: [:0]const u8, filename: []const u8, global_fns: *std.StringHashMap([]const u8)) !void {
    var tokenizer = Tokenizer.init(source);
    var prev_tag: Token.Tag = .eof;
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        if (tok.tag == .identifier and prev_tag == .keyword_fn) {
            const name = try arena.dupe(u8, source[tok.loc.start..tok.loc.end]);
            if (!global_fns.contains(name)) try global_fns.put(name, filename);
        }
        prev_tag = tok.tag;
    }
}

fn extractImports(arena: Allocator, source: [:0]const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(arena);
    var tokenizer = Tokenizer.init(source);
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        if (tok.tag != .keyword_const) continue;
        const alias_tok = tokenizer.next();
        if (alias_tok.tag != .identifier) continue;
        const alias = source[alias_tok.loc.start..alias_tok.loc.end];
        const eq_tok = tokenizer.next();
        if (eq_tok.tag != .equal) continue;
        const builtin_tok = tokenizer.next();
        if (builtin_tok.tag != .builtin) continue;
        if (!std.mem.eql(u8, source[builtin_tok.loc.start..builtin_tok.loc.end], "@import")) continue;
        const lp = tokenizer.next();
        if (lp.tag != .l_paren) continue;
        const str_tok = tokenizer.next();
        if (str_tok.tag != .string_literal) continue;
        const raw = source[str_tok.loc.start + 1 .. str_tok.loc.end - 1];
        if (std.mem.endsWith(u8, raw, ".zig")) {
            try map.put(try arena.dupe(u8, alias), try arena.dupe(u8, raw));
        }
    }
    return map;
}

fn extractEdges(
    arena: Allocator,
    filename: []const u8,
    source: [:0]const u8,
    imports: *const std.StringHashMap([]const u8),
    global_fns: *const std.StringHashMap([]const u8),
    edges: *std.ArrayList(Edge),
) !void {
    var tokenizer = Tokenizer.init(source);
    var depth: u32 = 0;
    var fn_stack: [32]FnScope = undefined;
    var fn_stack_len: u32 = 0;
    var pending_fn: ?[]const u8 = null;
    var ring_tags: [4]Token.Tag = .{ .eof, .eof, .eof, .eof };
    var ring_texts: [4][]const u8 = .{ "", "", "", "" };

    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        const text = source[tok.loc.start..tok.loc.end];
        switch (tok.tag) {
            .l_brace => {
                depth += 1;
                if (pending_fn) |name| {
                    if (fn_stack_len < fn_stack.len) {
                        fn_stack[fn_stack_len] = .{ .name = name, .depth = depth };
                        fn_stack_len += 1;
                    }
                    pending_fn = null;
                }
            },
            .r_brace => {
                if (depth > 0) depth -= 1;
                while (fn_stack_len > 0 and fn_stack[fn_stack_len - 1].depth > depth) fn_stack_len -= 1;
            },
            .keyword_fn => pending_fn = null,
            .identifier => {
                if (ring_tags[3] == .keyword_fn) pending_fn = try arena.dupe(u8, text);
            },
            else => {},
        }
        ring_tags[0] = ring_tags[1];
        ring_tags[1] = ring_tags[2];
        ring_tags[2] = ring_tags[3];
        ring_tags[3] = tok.tag;
        ring_texts[0] = ring_texts[1];
        ring_texts[1] = ring_texts[2];
        ring_texts[2] = ring_texts[3];
        ring_texts[3] = text;

        if (tok.tag != .l_paren or fn_stack_len == 0) continue;
        const current_fn = fn_stack[fn_stack_len - 1].name;

        if (ring_tags[2] == .identifier and ring_tags[1] == .period and ring_tags[0] == .identifier) {
            const qualifier = ring_texts[0];
            const callee = ring_texts[2];
            if (!isCallWorthy(callee)) continue;
            if (imports.get(qualifier)) |target_file| {
                try edges.append(.{
                    .from = .{ .file = filename, .func = current_fn },
                    .to = .{ .file = try arena.dupe(u8, target_file), .func = try arena.dupe(u8, callee) },
                });
            } else {
                const target_file = global_fns.get(callee) orelse filename;
                try edges.append(.{
                    .from = .{ .file = filename, .func = current_fn },
                    .to = .{ .file = target_file, .func = try arena.dupe(u8, callee) },
                });
            }
        } else if (ring_tags[2] == .identifier and ring_tags[1] != .period) {
            const callee = ring_texts[2];
            if (!isCallWorthy(callee)) continue;
            const target_file = global_fns.get(callee) orelse filename;
            try edges.append(.{
                .from = .{ .file = filename, .func = current_fn },
                .to = .{ .file = target_file, .func = try arena.dupe(u8, callee) },
            });
        }
    }
}

fn isCallWorthy(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] >= 'A' and name[0] <= 'Z') return false;
    const skip = [_][]const u8{
        "assert",       "maybe",      "unreachable", "undefined",
        "comptime",     "intCast",    "ptrCast",     "alignCast",
        "enumFromInt",  "intFromEnum", "memcpy",     "memset",
        "zeroes",       "copyForwards",
        "eql",          "get",        "put",         "append",
        "next",         "skip",       "items",       "deinit",
        "print",        "parseInt",   "startsWith",  "endsWith",
        "indexOf",      "parseIp4",   "toBytes",     "getOsSockLen",
        "format",       "allocPrint",
        "socket",       "bind",       "listen",      "close",
        "setsockopt",   "epoll_create1", "epoll_ctl", "epoll_wait",
        "sqlite3_open", "sqlite3_close", "sqlite3_exec",
        "sqlite3_prepare_v2", "sqlite3_busy_timeout",
        "sqlite3_step", "sqlite3_reset", "sqlite3_bind_blob",
        "sqlite3_bind_int", "sqlite3_bind_int64",
        "sqlite3_column_blob", "sqlite3_column_int",
        "sqlite3_column_bytes",
        "err",          "info",       "debug",       "warn",
        "exit",         "args",       "time",
        "orderedRemove", "contains",  "getOrPut",
        "ensureTotalCapacity", "readFileAllocOptions",
    };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return false;
    }
    return true;
}
