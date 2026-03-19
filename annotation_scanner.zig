//! Annotation scanner — verifies sidecar handler exhaustiveness.
//!
//! Scans source files for `// [phase] .operation` annotations.
//! Reports missing operations, duplicates, and invalid annotations
//! with clickable file:line locations.
//!
//! Language-agnostic: comment prefix detected from file extension.
//! Only registers annotations where the next non-empty line is code
//! (not a comment), preventing false positives from documentation.
//!
//! Usage: zig build scan -- ts/
//!        zig build scan -- py/handlers/

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");

const Operation = message.Operation;

/// Phases the scanner recognizes.
const Phase = enum {
    translate,
    execute,
    render,
};

/// A registered annotation with its source location and export name.
const Annotation = struct {
    phase: Phase,
    operation: []const u8,
    file: []const u8,
    line: u32,
    func_name: []const u8,
};

/// Comment prefix by file extension.
fn comment_prefix(path: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".go") or
        std.mem.endsWith(u8, path, ".rs") or
        std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".cpp"))
    {
        return "//";
    }
    if (std.mem.endsWith(u8, path, ".py") or
        std.mem.endsWith(u8, path, ".rb") or
        std.mem.endsWith(u8, path, ".sh"))
    {
        return "#";
    }
    if (std.mem.endsWith(u8, path, ".lua") or
        std.mem.endsWith(u8, path, ".hs"))
    {
        return "--";
    }
    return null;
}

/// Parse an annotation from a line. Returns the phase and operation name,
/// or null if the line is not a valid annotation.
/// Format: `{prefix} [{phase}] .{operation}`
fn parse_annotation(line: []const u8, prefix: []const u8) ?struct { phase: Phase, operation: []const u8 } {
    // Strip leading whitespace.
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }

    // Must start with the comment prefix.
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];

    // Skip whitespace after prefix.
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    // Must start with '['.
    if (rest.len == 0 or rest[0] != '[') return null;
    rest = rest[1..];

    // Parse phase name until ']'.
    const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    const phase_str = rest[0..close];
    rest = rest[close + 1 ..];

    const phase: Phase = if (std.mem.eql(u8, phase_str, "translate"))
        .translate
    else if (std.mem.eql(u8, phase_str, "execute"))
        .execute
    else if (std.mem.eql(u8, phase_str, "render"))
        .render
    else
        return null;

    // Skip whitespace after ']'.
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    // Must start with '.'.
    if (rest.len == 0 or rest[0] != '.') return null;
    rest = rest[1..];

    // Operation name: alphanumeric + underscore until whitespace or end.
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
        end += 1;
    }
    if (end == 0) return null;

    return .{ .phase = phase, .operation = rest[0..end] };
}

/// Returns true if a line is a comment (starts with the comment prefix after whitespace).
fn is_comment(line: []const u8, prefix: []const u8) bool {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }
    return std.mem.startsWith(u8, trimmed, prefix);
}

/// Extract the function/export name from a code line.
/// Handles common patterns across languages:
///   export function createProduct(   → "createProduct"
///   export async function foo(       → "foo"
///   export const foo =               → "foo"
///   def create_product(              → "create_product"
///   func createProduct(              → "createProduct"
///   fn create_product(               → "create_product"
///   pub fn create_product(           → "create_product"
/// Returns null if no name can be extracted.
fn extract_func_name(line: []const u8) ?[]const u8 {
    var rest = line;
    // Strip leading whitespace.
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];

    // Skip keywords: export, pub, async, static
    const skip_keywords = [_][]const u8{ "export ", "pub ", "async ", "static " };
    var changed = true;
    while (changed) {
        changed = false;
        for (skip_keywords) |kw| {
            if (std.mem.startsWith(u8, rest, kw)) {
                rest = rest[kw.len..];
                // Skip extra whitespace after keyword.
                while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
                changed = true;
            }
        }
    }

    // Match function/def/fn/func keyword.
    const func_keywords = [_][]const u8{ "function ", "def ", "fn ", "func " };
    for (func_keywords) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) {
            rest = rest[kw.len..];
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            return extract_identifier(rest);
        }
    }

    // Match "const NAME =" (TS arrow functions / const exports).
    if (std.mem.startsWith(u8, rest, "const ")) {
        rest = rest[6..];
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        return extract_identifier(rest);
    }

    return null;
}

fn extract_identifier(s: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < s.len and (std.ascii.isAlphanumeric(s[end]) or s[end] == '_')) {
        end += 1;
    }
    return if (end > 0) s[0..end] else null;
}

/// Returns true if a line is empty or whitespace-only.
fn is_empty(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return false;
    }
    return true;
}

/// All valid operation names, known at comptime from the Operation enum.
const valid_operations = blk: {
    const fields = @typeInfo(Operation).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    break :blk names;
};

fn is_valid_operation(name: []const u8) bool {
    for (valid_operations) |op| {
        if (std.mem.eql(u8, op, name)) return true;
    }
    return false;
}

pub fn main() !void {
    // Arena allocator — freed all at once on exit. No per-item cleanup
    // needed for a short-lived build tool.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.skip(); // binary name

    const scan_dir = args.next() orelse {
        std.debug.print("Usage: annotation-scanner <directory> [--emit=<output-file>]\n", .{});
        std.process.exit(1);
    };

    // Optional: --emit=generated/dispatch.generated.ts
    var emit_path: ?[]const u8 = null;
    if (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--emit=")) {
            emit_path = arg[7..];
        }
    }

    var annotations = std.ArrayList(Annotation).init(allocator);
    defer annotations.deinit();

    var errors: u32 = 0;
    const stderr = std.io.getStdErr().writer();

    // Scan all files in the directory.
    var dir = std.fs.cwd().openDir(scan_dir, .{ .iterate = true }) catch |err| {
        try stderr.print("error: cannot open directory '{s}': {}\n", .{ scan_dir, err });
        std.process.exit(1);
    };
    defer dir.close();

    // Walk recursively — handles ts/products/create.ts etc.
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const prefix = comment_prefix(entry.basename) orelse continue;

        // Build full path for error messages.
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scan_dir, entry.path });

        const content = dir.readFileAlloc(allocator, entry.path, 1024 * 1024) catch |err| {
            try stderr.print("error: cannot read '{s}': {}\n", .{ path, err });
            errors += 1;
            continue;
        };
        defer allocator.free(content);

        // Split into lines and scan.
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var prev_annotation: ?struct { phase: Phase, operation: []const u8, line: u32 } = null;

        while (lines.next()) |line| {
            line_num += 1;

            if (prev_annotation) |ann| {
                // Check if the line after the annotation is code.
                if (!is_empty(line)) {
                    if (is_comment(line, prefix)) {
                        // Next non-empty line is a comment — annotation is in docs, skip.
                        try stderr.print("warning: {s}:{d}: annotation followed by comment, skipping\n", .{ path, ann.line });
                        prev_annotation = null;
                        // Don't continue — this line might itself be an annotation.
                    } else {
                        // Next non-empty line is code — register the annotation.
                        if (!is_valid_operation(ann.operation)) {
                            try stderr.print("error: {s}:{d}: unknown operation '.{s}'\n", .{ path, ann.line, ann.operation });
                            errors += 1;
                        } else {
                            const func_name = extract_func_name(line) orelse {
                                try stderr.print("error: {s}:{d}: cannot extract function name from line after annotation\n", .{ path, line_num });
                                errors += 1;
                                prev_annotation = null;
                                continue;
                            };
                            try annotations.append(.{
                                .phase = ann.phase,
                                .operation = try allocator.dupe(u8, ann.operation),
                                .file = try allocator.dupe(u8, path),
                                .line = ann.line,
                                .func_name = try allocator.dupe(u8, func_name),
                            });
                        }
                        prev_annotation = null;
                        continue;
                    }
                } else {
                    // Empty line — still waiting for code.
                    continue;
                }
            }

            // Check if this line is an annotation.
            if (parse_annotation(line, prefix)) |ann| {
                prev_annotation = .{ .phase = ann.phase, .operation = ann.operation, .line = line_num };
            }
        }

        // Handle annotation at end of file (no code after it).
        if (prev_annotation) |ann| {
            try stderr.print("warning: {s}:{d}: annotation at end of file, no code follows\n", .{ path, ann.line });
        }
    }

    // Check for duplicates.
    for (annotations.items, 0..) |a, i| {
        for (annotations.items[i + 1 ..]) |b| {
            if (a.phase == b.phase and std.mem.eql(u8, a.operation, b.operation)) {
                try stderr.print("error: duplicate handler for [{s}] .{s}\n  --> {s}:{d}\n  --> {s}:{d}\n", .{
                    @tagName(a.phase), a.operation, a.file, a.line, b.file, b.line,
                });
                errors += 1;
            }
        }
    }

    // Check exhaustiveness — every non-root operation needs a handler for each phase.
    const phases = [_]Phase{ .translate, .execute, .render };
    for (phases) |phase| {
        for (valid_operations) |op| {
            if (std.mem.eql(u8, op, "root")) continue; // WAL sentinel, not a real operation.

            var found = false;
            for (annotations.items) |ann| {
                if (ann.phase == phase and std.mem.eql(u8, ann.operation, op)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try stderr.print("error: missing handler for [{s}] .{s}\n", .{ @tagName(phase), op });
                errors += 1;
            }
        }
    }

    // Summary.
    const stdout = std.io.getStdOut().writer();
    if (errors > 0) {
        try stderr.print("\n{d} error(s) found.\n", .{errors});
        std.process.exit(1);
    }

    try stdout.print("OK: {d} annotations in {s}/\n", .{ annotations.items.len, scan_dir });

    // Generate dispatch file if --emit was specified.
    if (emit_path) |out_path| {
        try emit_dispatch(allocator, out_path, annotations.items);
        try stdout.print("Generated: {s}\n", .{out_path});
    }
}

/// Generate the TypeScript dispatch file.
fn emit_dispatch(allocator: std.mem.Allocator, out_path: []const u8, annotations: []const Annotation) !void {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll("// Auto-generated by `zig build scan` — do not edit.\n\n");
    try w.writeAll("import * as net from 'net';\nimport { unlinkSync } from 'fs';\n");
    try w.writeAll("import {\n");
    try w.writeAll("  readTranslateRequest, writeTranslateResponse,\n");
    try w.writeAll("  readExecuteRenderRequest, writeExecuteRenderResponse,\n");
    try w.writeAll("  translate_request_size, translate_response_size,\n");
    try w.writeAll("  execute_render_request_size, execute_render_response_size,\n");
    try w.writeAll("  TagValues,\n");
    try w.writeAll("  type TranslateRequest, type TranslateResponse,\n");
    try w.writeAll("  type ExecuteRenderRequest, type ExecuteRenderResponse,\n");
    try w.writeAll("} from './types.generated.ts';\n\n");

    // Collect unique files and their imports.
    var seen_imports = std.StringHashMap(void).init(allocator);
    for (annotations) |ann| {
        // Build import key: "file:func_name"
        const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ ann.file, ann.func_name });
        if (!seen_imports.contains(key)) {
            try seen_imports.put(key, {});
            // Compute relative path from generated/ to the source file.
            // scan_dir is e.g. "ts/", file is "ts/products.ts" → "../ts/products.ts"
            try w.print("import {{ {s} }} from '../{s}';\n", .{ ann.func_name, ann.file });
        }
    }
    try w.writeByte('\n');

    // Dispatch tables.
    for ([_]Phase{ .translate, .execute, .render }) |phase| {
        try w.print("const {s}Handlers: Record<string, Function> = {{\n", .{@tagName(phase)});
        for (annotations) |ann| {
            if (ann.phase != phase) continue;
            try w.print("  '{s}': {s},\n", .{ ann.operation, ann.func_name });
        }
        try w.writeAll("};\n\n");
    }

    // Socket server.
    try w.writeAll(
        \\const socketPath = process.argv[2];
        \\if (!socketPath) { console.error('Usage: node dispatch.generated.ts <socket-path>'); process.exit(1); }
        \\
        \\const server = net.createServer((conn) => {
        \\  console.log('[sidecar] client connected');
        \\  let pending = Buffer.alloc(0);
        \\  conn.on('data', (chunk: Buffer) => {
        \\    pending = Buffer.concat([pending, chunk]);
        \\    while (pending.length > 0) {
        \\      const tag = pending[0];
        \\      if (tag === TagValues.translate) {
        \\        if (pending.length < translate_request_size) break;
        \\        const req = readTranslateRequest(new Uint8Array(pending.buffer, pending.byteOffset, translate_request_size), 0);
        \\        pending = pending.subarray(translate_request_size);
        \\        const handler = translateHandlers[req.method + ' ' + req.path] || translateHandlers[req.operation];
        \\        const resp: TranslateResponse = handler ? handler(req) : { id: '0'.repeat(32), body: new Uint8Array(672), found: 0, operation: 'root' };
        \\        const out = new Uint8Array(translate_response_size);
        \\        writeTranslateResponse(out, 0, resp);
        \\        conn.write(out);
        \\      } else if (tag === TagValues.execute_render) {
        \\        if (pending.length < execute_render_request_size) break;
        \\        const req = readExecuteRenderRequest(new Uint8Array(pending.buffer, pending.byteOffset, execute_render_request_size), 0);
        \\        pending = pending.subarray(execute_render_request_size);
        \\        const execHandler = executeHandlers[req.operation];
        \\        const renderHandler = renderHandlers[req.operation];
        \\        const execResult = execHandler ? execHandler(req.cache, req.body) : { status: 'ok', writes: [] };
        \\        const html = renderHandler ? renderHandler(req.operation, execResult.status, execResult) : '<div>OK</div>';
        \\        const resp: ExecuteRenderResponse = {
        \\          status: execResult.status || 'ok',
        \\          writes_len: 0, result_tag: 0,
        \\          result: new Uint8Array(47248),
        \\          writes: Array.from({ length: 21 }, () => ({ tag: 0, reserved_tag: new Uint8Array(15), data: new Uint8Array(3632) })),
        \\          html,
        \\        };
        \\        const out = new Uint8Array(execute_render_response_size);
        \\        writeExecuteRenderResponse(out, 0, resp);
        \\        conn.write(out);
        \\      } else {
        \\        console.error('[sidecar] unknown tag:', tag);
        \\        conn.destroy();
        \\        return;
        \\      }
        \\    }
        \\  });
        \\  conn.on('close', () => console.log('[sidecar] client disconnected'));
        \\  conn.on('error', (err: Error) => console.error('[sidecar] error:', err.message));
        \\});
        \\
        \\try { unlinkSync(socketPath); } catch {}
        \\server.listen(socketPath, () => console.log(`[sidecar] listening on ${socketPath}`));
        \\process.on('SIGINT', () => { server.close(); process.exit(0); });
        \\
    );

    // Write the file.
    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// =====================================================================
// Tests
// =====================================================================

test "parse_annotation valid" {
    const result = parse_annotation("// [execute] .create_product", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .execute);
    try std.testing.expect(std.mem.eql(u8, result.?.operation, "create_product"));
}

test "parse_annotation with leading whitespace" {
    const result = parse_annotation("  // [render] .get_product", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .render);
}

test "parse_annotation python style" {
    const result = parse_annotation("# [translate] .list_products", "#");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .translate);
    try std.testing.expect(std.mem.eql(u8, result.?.operation, "list_products"));
}

test "parse_annotation invalid phase" {
    try std.testing.expect(parse_annotation("// [unknown] .foo", "//") == null);
}

test "parse_annotation no dot" {
    try std.testing.expect(parse_annotation("// [execute] create_product", "//") == null);
}

test "parse_annotation not a comment" {
    try std.testing.expect(parse_annotation("export function foo()", "//") == null);
}

test "is_comment" {
    try std.testing.expect(is_comment("// hello", "//"));
    try std.testing.expect(is_comment("  // hello", "//"));
    try std.testing.expect(!is_comment("export function", "//"));
    try std.testing.expect(is_comment("# hello", "#"));
}

test "is_empty" {
    try std.testing.expect(is_empty(""));
    try std.testing.expect(is_empty("  \t  "));
    try std.testing.expect(!is_empty("code"));
}

test "is_valid_operation" {
    try std.testing.expect(is_valid_operation("create_product"));
    try std.testing.expect(is_valid_operation("get_product"));
    try std.testing.expect(is_valid_operation("root"));
    try std.testing.expect(!is_valid_operation("nonexistent"));
    try std.testing.expect(!is_valid_operation(""));
}

test "comment_prefix by extension" {
    try std.testing.expect(std.mem.eql(u8, comment_prefix("foo.ts").?, "//"));
    try std.testing.expect(std.mem.eql(u8, comment_prefix("bar.py").?, "#"));
    try std.testing.expect(std.mem.eql(u8, comment_prefix("baz.lua").?, "--"));
    try std.testing.expect(comment_prefix("readme.md") == null);
}

test "extract_func_name TypeScript patterns" {
    // export function
    try std.testing.expect(std.mem.eql(u8, extract_func_name("export function createProduct(cache, body) {").?, "createProduct"));
    // export async function
    try std.testing.expect(std.mem.eql(u8, extract_func_name("export async function getProduct(cache) {").?, "getProduct"));
    // export const
    try std.testing.expect(std.mem.eql(u8, extract_func_name("export const listProducts = (cache) => {").?, "listProducts"));
    // leading whitespace
    try std.testing.expect(std.mem.eql(u8, extract_func_name("  export function foo() {}").?, "foo"));
}

test "extract_func_name other languages" {
    // Python
    try std.testing.expect(std.mem.eql(u8, extract_func_name("def create_product(cache, body):").?, "create_product"));
    // Go
    try std.testing.expect(std.mem.eql(u8, extract_func_name("func CreateProduct(cache Cache) {").?, "CreateProduct"));
    // Zig/Rust
    try std.testing.expect(std.mem.eql(u8, extract_func_name("pub fn create_product(self) void {").?, "create_product"));
    try std.testing.expect(std.mem.eql(u8, extract_func_name("fn create_product() {").?, "create_product"));
}

test "extract_func_name returns null for non-function lines" {
    try std.testing.expect(extract_func_name("// just a comment") == null);
    try std.testing.expect(extract_func_name("") == null);
    try std.testing.expect(extract_func_name("import { foo } from 'bar';") == null);
}
