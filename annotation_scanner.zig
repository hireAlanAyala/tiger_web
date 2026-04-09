//! Annotation scanner — the framework's compiler for handler correctness.
//!
//! Scans source files for `// [phase] .operation` annotations.
//! Reports missing operations, duplicates, and invalid annotations
//! with clickable file:line locations.
//!
//! Language-agnostic: comment prefix detected from file extension.
//! Only registers annotations where the next non-empty line is code
//! (not a comment), preventing false positives from documentation.
//!
//! ## Status exhaustiveness
//!
//! Extracts status literals from [handle] bodies and handled statuses
//! from [render] bodies using language-specific patterns. Errors if
//! render doesn't cover every status that handle can return.
//!
//! Same check for all languages — Zig, TypeScript, Ruby, anything with
//! a language adapter. No generated types, no generated enums. The
//! scanner reads source text and compares two sets. This is deliberate:
//!
//! - **No sidecar type generation.** Sidecar languages don't get LSP
//!   type help for status values (status is `string`, not a union).
//!   This trade-off buys language-agnostic enforcement: adding a new
//!   sidecar language is one adapter struct, not a type generation
//!   pipeline. AI-generated handlers get the same feedback from
//!   `zig build scan`. CI catches drift with one build step.
//!
//! - **No catch-all handling.** Render must name every status explicitly.
//!   Negation patterns (`!== "ok"`, `else`, default branches) are not
//!   recognized — they hide which statuses are actually handled. Each
//!   status gets its own branch, each branch is visible to the scanner,
//!   each omission produces a specific error naming the missing status.
//!   Same principle as TigerBeetle's "assert one thing at a time."
//!
//! For Zig handlers, the compiler's exhaustive switch provides a second
//! layer of enforcement (redundant but harmless). For sidecar languages,
//! the scanner is the only enforcement.
//!
//! ## Manifest
//!
//! Outputs a JSON manifest for language-specific adapters to consume.
//! The adapter reads the manifest, extracts function names from the
//! source files, and generates the dispatch file in the target language.
//!
//! ## Usage
//!
//!     zig build scan
//!     zig build scan -- --manifest=generated/manifest.json

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");

const Operation = message.Operation;

/// Phases the scanner recognizes.
const Phase = enum {
    translate,
    prefetch,
    execute,
    render,
    worker,
};

/// Parsed route match directive — `// match GET /products/:id`.
/// Optional query param names — `// query q` extracts ?q= into params.
const RouteMatch = struct {
    method: Method,
    pattern: []const u8,
    line: u32,
    query_params: QueryParams = .{},

    const max_query_params = 4;
    const QueryParams = struct {
        names: [max_query_params][]const u8 = .{&.{}} ** max_query_params,
        len: u8 = 0,

        fn add(self: *QueryParams, name: []const u8) void {
            assert(self.len < max_query_params);
            self.names[self.len] = name;
            self.len += 1;
        }
    };

    /// HTTP methods recognized in match directives. Superset of
    /// framework's http.Method — the scanner accepts PATCH even though
    /// the framework parser doesn't (yet). Comptime assertion below
    /// verifies the framework's methods are a subset.
    const Method = enum { get, post, put, delete, patch };

    /// Free the duped pattern. Single free site for the single dupe site.
    fn deinit(self: RouteMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        // query param names are duped too
        for (self.query_params.names[0..self.query_params.len]) |name| {
            allocator.free(name);
        }
    }
};

const http = @import("framework/http.zig");
comptime {
    // Every framework HTTP method must exist in RouteMatch.Method.
    // If the framework adds a method, the scanner must recognize it.
    for (@typeInfo(http.Method).@"enum".fields) |f| {
        assert(@hasField(RouteMatch.Method, f.name));
    }
}

/// Extracted prefetch query specification — used to generate
/// prefetch.generated.zig for 1-RT dispatch. The framework
/// executes these SQL queries natively instead of calling
/// the sidecar for the prefetch phase.
const PrefetchQuery = struct {
    sql: []const u8,
    mode: enum { query, query_all },
    params: []const ParamSpec,
    key: []const u8, // return key name e.g. "product", "products"
};

const ParamSpec = struct {
    source: enum { id, body_field, literal_int, body_json_array },
    field: []const u8, // body field name when source = .body_field or .body_json_array
    subfield: []const u8 = "", // nested field for body_json_array (e.g., "product_id" from items[].product_id)
    int_val: i64, // value when source = .literal_int
};

/// A registered annotation with its source location.
const Annotation = struct {
    phase: Phase,
    operation: []const u8,
    file: []const u8,
    line: u32,
    has_body: bool,
    route_match: ?RouteMatch = null,
    extraction_failed: bool = false, // SQL extraction attempted but failed
    prefetch_queries: []const PrefetchQuery = &.{},
    param_hints: [max_annotation_param_hints]?ParamHint = .{null} ** max_annotation_param_hints,
    param_hint_count: u8 = 0,
    id_field: ?[]const u8 = null, // [worker] only: field name in worker result for entity id
};

const max_annotation_param_hints = 4;
const ParamHint = struct {
    source: enum { json_array },
    field: []const u8,
    subfield: []const u8,
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
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }

    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    if (rest.len == 0 or rest[0] != '[') return null;
    rest = rest[1..];

    const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    const phase_str = rest[0..close];
    rest = rest[close + 1 ..];

    // User-facing phase names only. Internal names (translate/execute)
    // belong to the Zig framework, not handler annotations.
    const phase: Phase = if (std.mem.eql(u8, phase_str, "route"))
        .translate
    else if (std.mem.eql(u8, phase_str, "prefetch"))
        .prefetch
    else if (std.mem.eql(u8, phase_str, "handle"))
        .execute
    else if (std.mem.eql(u8, phase_str, "render"))
        .render
    else if (std.mem.eql(u8, phase_str, "worker"))
        .worker
    else
        return null;

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    if (rest.len == 0 or rest[0] != '.') return null;
    rest = rest[1..];

    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
        end += 1;
    }
    if (end == 0) return null;

    return .{ .phase = phase, .operation = rest[0..end] };
}

/// Returns true if a line is a comment.
fn is_comment(line: []const u8, prefix: []const u8) bool {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }
    return std.mem.startsWith(u8, trimmed, prefix);
}

/// Returns true if a line is empty or whitespace-only.
fn is_empty(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return false;
    }
    return true;
}

/// Parse a match directive from a comment line.
/// Format: `{prefix} match {METHOD} {/path/pattern}`
/// Returns null if the line is not a match directive.
fn parse_match_directive(line: []const u8, prefix: []const u8) ?struct { method: RouteMatch.Method, pattern: []const u8 } {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }

    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    if (!std.mem.startsWith(u8, rest, "match ")) return null;
    rest = rest[6..];

    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    // Parse HTTP method.
    const method_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const method_str = rest[0..method_end];
    const method: RouteMatch.Method =
        if (std.ascii.eqlIgnoreCase(method_str, "GET")) .get
        else if (std.ascii.eqlIgnoreCase(method_str, "POST")) .post
        else if (std.ascii.eqlIgnoreCase(method_str, "PUT")) .put
        else if (std.ascii.eqlIgnoreCase(method_str, "DELETE")) .delete
        else if (std.ascii.eqlIgnoreCase(method_str, "PATCH")) .patch
        else return null;

    rest = rest[method_end..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    // Parse path pattern — must start with /.
    if (rest.len == 0 or rest[0] != '/') return null;

    // Trim trailing whitespace.
    var pattern_end = rest.len;
    while (pattern_end > 0 and (rest[pattern_end - 1] == ' ' or rest[pattern_end - 1] == '\t' or rest[pattern_end - 1] == '\r')) {
        pattern_end -= 1;
    }
    if (pattern_end == 0) return null;

    return .{ .method = method, .pattern = rest[0..pattern_end] };
}

/// Parse `// query <name>` directive. Returns the query param name or null.
/// Name must be a non-empty alphanumeric identifier (same rules as :param names).
fn parse_query_directive(line: []const u8, prefix: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const after_prefix = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
    if (!std.mem.startsWith(u8, after_prefix, "query ")) return null;
    const name = std.mem.trimRight(u8, std.mem.trimLeft(u8, after_prefix[6..], " \t"), " \t\r");
    if (name.len == 0) return null;
    // Validate: alphanumeric + underscore only.
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    return name;
}

/// Validate a route pattern's structure. Returns an error message or null if valid.
/// Rules:
///   - Must start with /
///   - Segments between / must be non-empty (no //)
///   - Param names after : must be non-empty identifiers
///   - No trailing slash (except root /)
fn validate_route_pattern(pattern: []const u8) ?[]const u8 {
    if (pattern.len == 0) return "empty pattern";
    if (pattern[0] != '/') return "must start with /";
    if (pattern.len == 1) return null; // root "/" is valid

    // No trailing slash.
    if (pattern[pattern.len - 1] == '/') return "trailing slash";

    // Walk segments.
    var pos: usize = 1; // skip leading /
    while (pos < pattern.len) {
        const next_slash = std.mem.indexOfScalarPos(u8, pattern, pos, '/');
        const seg_end = next_slash orelse pattern.len;
        const segment = pattern[pos..seg_end];

        if (segment.len == 0) return "empty segment (double slash)";

        // If segment starts with :, validate param name.
        if (segment[0] == ':') {
            if (segment.len == 1) return "empty param name after :";
            for (segment[1..]) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '_') return "invalid character in param name";
            }
        }

        pos = if (next_slash) |s| s + 1 else pattern.len;
    }

    return null;
}

/// Map internal phase names back to user-facing names for error messages.
/// Parse `// @param json_array field.subfield` directive.
/// Returns field and subfield, or null if not a param directive.
fn parse_param_directive(line: []const u8, prefix: []const u8) ?struct { field: []const u8, subfield: []const u8 } {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const after_prefix = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
    if (!std.mem.startsWith(u8, after_prefix, "@param ")) return null;
    const rest = std.mem.trimLeft(u8, after_prefix["@param ".len..], " \t");

    // Parse: json_array field.subfield
    if (!std.mem.startsWith(u8, rest, "json_array ")) return null;
    const spec = std.mem.trimRight(u8, std.mem.trimLeft(u8, rest["json_array ".len..], " \t"), " \t\r");

    // Split field.subfield
    const dot = std.mem.indexOfScalar(u8, spec, '.') orelse return null;
    if (dot == 0 or dot + 1 >= spec.len) return null;
    return .{
        .field = spec[0..dot],
        .subfield = spec[dot + 1 ..],
    };
}

/// Parse a `// id field_name` directive for workers.
/// Declares which field of the worker result contains the entity id.
fn parse_id_directive(line: []const u8, prefix: []const u8) ?[]const u8 {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    if (!std.mem.startsWith(u8, rest, "id ")) return null;
    rest = rest[3..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
        end += 1;
    }
    if (end == 0) return null;
    return rest[0..end];
}

fn user_phase_name(phase: Phase) []const u8 {
    return switch (phase) {
        .translate => "route",
        .prefetch => "prefetch",
        .execute => "handle",
        .render => "render",
        .worker => "worker",
    };
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

// =====================================================================
// Status extraction — language-adapter pattern matching
// =====================================================================

/// Maximum statuses per handler. Must fit all Status enum variants.
const max_statuses = 16;
comptime {
    // If Status gains more variants than max_statuses, this fires.
    assert(@typeInfo(message.Status).@"enum".fields.len <= max_statuses);
}

/// Fixed-size set of status names, deduplicated.
const StatusSet = struct {
    names: [max_statuses][]const u8 = .{&.{}} ** max_statuses,
    len: u8 = 0,

    fn add(self: *StatusSet, name: []const u8) void {
        assert(name.len > 0);
        for (self.names[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing, name)) return; // deduplicate
        }
        assert(self.len < max_statuses);
        self.names[self.len] = name;
        self.len += 1;
    }

    fn slice(self: *const StatusSet) []const []const u8 {
        return self.names[0..self.len];
    }
};

/// Per-operation status extraction result.
const OperationStatuses = struct {
    operation: []const u8,
    statuses: StatusSet,
};

/// Language-specific pattern for extracting status literals.
/// The scanner searches for `prefix` in each byte position, then reads
/// the identifier that follows (terminated by `terminators` characters).
/// If `suffix` is set, the suffix must appear after the identifier
/// (with optional whitespace) for the match to count.
///
/// Example: Zig render uses prefix=".", suffix="=>" to match `.ok =>`
/// (switch arm) but NOT `.product` (field access) or `.active` (flag).
/// Without the suffix, every dot-access in the function body would be
/// extracted as a status name.
const StatusPattern = struct {
    prefix: []const u8,
    terminators: []const u8,
    suffix: ?[]const u8 = null,
};

/// Language adapter — extraction patterns for handle and render phases.
///
/// Adding a new sidecar language: define one LanguageAdapter with the
/// language's status patterns. No type generation, no compiler plugin.
/// The scanner's text matching is sufficient because:
/// - handle statuses are always literals in return expressions
/// - render statuses are always literals in switch/case/comparison
/// - the self-correcting property catches any false negatives
///
/// Render patterns must match EXPLICIT status references only — not
/// negation, not default/else, not catch-all. If the scanner can't see
/// which status a branch handles, it can't verify the branch exists.
const LanguageAdapter = struct {
    extensions: []const []const u8,
    handle_patterns: []const StatusPattern,
    render_patterns: []const StatusPattern,
    sql_quote: u8 = '"', // quote character for SQL string literals
};

/// Zig adapter.
/// handle: `{ .status = .not_found }` (HandleResult literal) → extracts status name
///   The `{ .status = .` prefix distinguishes struct literal init from field
///   assignment (`order_result.status = .pending` has no leading `{`).
///   Legacy patterns (`read_only(.`, `single(.`) kept for scanner test content.
/// render: `.not_found =>` (switch arm) → extracts status name
const zig_adapter = LanguageAdapter{
    .extensions = &.{".zig"},
    .handle_patterns = &.{
        .{ .prefix = "{ .status = .", .terminators = " ,)};:\t\n" },
        .{ .prefix = "read_only(.", .terminators = ",)};: \t\n" },
        .{ .prefix = "single(.", .terminators = ",)};: \t\n" },
    },
    .render_patterns = &.{
        .{ .prefix = ".", .terminators = " \t\n=>,)", .suffix = "=>" },
    },
};

/// TypeScript adapter.
/// handle: `status: "not_found"` → "not_found"
/// render: `case "not_found":` or `=== "not_found"` → status names
///
/// `!==` is deliberately excluded. `if (status !== "ok")` is a catch-all
/// that handles every non-ok status in one branch — the scanner can't
/// tell which statuses that branch covers. The developer must write
/// `if (status === "not_found")` for each status so the scanner can
/// verify each one exists.
const ts_adapter = LanguageAdapter{
    .extensions = &.{ ".ts", ".js" },
    .handle_patterns = &.{
        .{ .prefix = "status: \"", .terminators = "\"" },
    },
    .render_patterns = &.{
        .{ .prefix = "case \"", .terminators = "\"" },
        .{ .prefix = "=== \"", .terminators = "\"" },
    },
};

const adapters = [_]LanguageAdapter{ zig_adapter, ts_adapter };

comptime {
    for (adapters) |a| {
        assert(a.extensions.len > 0);
        assert(a.handle_patterns.len > 0);
        assert(a.render_patterns.len > 0);
        for (a.handle_patterns) |p| assert(p.prefix.len > 0);
        for (a.render_patterns) |p| assert(p.prefix.len > 0);
    }
}

/// Select adapter based on file extension.
fn find_adapter(path: []const u8) ?LanguageAdapter {
    for (adapters) |a| {
        for (a.extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) return a;
        }
    }
    return null;
}

// Aliases for tests.
const zig_status_patterns = zig_adapter.handle_patterns;
const ts_status_patterns = ts_adapter.handle_patterns;

/// Extract status literals from a function body.
///
/// Locates the function body by finding the first `{` at or after
/// `start_line` (1-based), then scans with brace-depth tracking
/// until the body closes. Within the body, applies each pattern
/// to extract status names.
///
/// Used for both handle and render extraction — patterns differ.
///
/// Known limitation: brace counting does not skip string literals or
/// comments. A `{` or `}` inside a string would throw off the depth.
/// In practice, handle/render bodies don't contain brace characters
/// in string literals. If they did, the scanner would extract too few
/// or too many statuses — self-correcting via the exhaustiveness check.
fn extract_statuses_from_body(
    content: []const u8,
    start_line: u32,
    patterns: []const StatusPattern,
) StatusSet {
    assert(start_line > 0); // 1-based
    var result = StatusSet{};

    // Advance to start_line (1-based).
    var pos: usize = 0;
    var line_num: u32 = 1;
    while (line_num < start_line and pos < content.len) {
        if (content[pos] == '\n') line_num += 1;
        pos += 1;
    }

    // Find the opening brace of the function body.
    const brace_start = std.mem.indexOfScalar(u8, content[pos..], '{') orelse return result;
    pos = pos + brace_start + 1;
    var depth: u32 = 1;

    // Scan through the function body.
    while (pos < content.len and depth > 0) {
        switch (content[pos]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                pos += 1;
                continue;
            },
            else => {},
        }
        if (depth > 0) {
            for (patterns) |pat| {
                if (pos + pat.prefix.len <= content.len and
                    std.mem.eql(u8, content[pos..][0..pat.prefix.len], pat.prefix))
                {
                    const name_start = pos + pat.prefix.len;
                    var name_end = name_start;
                    while (name_end < content.len) {
                        if (is_terminator(content[name_end], pat.terminators)) break;
                        if (!std.ascii.isAlphanumeric(content[name_end]) and content[name_end] != '_') break;
                        name_end += 1;
                    }
                    if (name_end > name_start) {
                        // If pattern has a suffix, verify it follows the identifier.
                        if (pat.suffix) |suffix| {
                            var check = name_end;
                            while (check < content.len and (content[check] == ' ' or content[check] == '\t')) check += 1;
                            if (check + suffix.len <= content.len and
                                std.mem.eql(u8, content[check..][0..suffix.len], suffix))
                            {
                                result.add(content[name_start..name_end]);
                            }
                        } else {
                            result.add(content[name_start..name_end]);
                        }
                    }
                }
            }
        }
        pos += 1;
    }

    return result;
}

/// Extract statuses from a handle() body. Always includes "ok" because
/// HandlerContext defaults status to .ok — the variant must exist.
/// Bodyless handles (read-only) return only ok, set by the caller.
fn extract_statuses_from_handle(
    content: []const u8,
    start_line: u32,
    patterns: []const StatusPattern,
) StatusSet {
    var result = extract_statuses_from_body(content, start_line, patterns);
    result.add("ok");
    assert(result.len >= 1); // "ok" was just added
    assert(has_name(&result, "ok")); // pair: add promised, we verify
    return result;
}

fn is_terminator(ch: u8, terminators: []const u8) bool {
    for (terminators) |term| {
        if (ch == term) return true;
    }
    return false;
}

/// Scan a single file's content for annotations. Returns the number of errors found.
/// Extracted from main() for testability.
///
/// All string fields on Annotation (operation, file, route_match.pattern)
/// are duped via the allocator. In main() this is an arena — no individual
/// frees needed. In tests, std.testing.allocator catches leaks.
fn scan_file_content(
    allocator: std.mem.Allocator,
    content: []const u8,
    prefix: []const u8,
    path: []const u8,
    annotations: *std.ArrayList(Annotation),
) !u32 {
    var errors: u32 = 0;
    const stderr = std.io.getStdErr().writer();

    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var prev_annotation: ?struct { phase: Phase, operation: []const u8, line: u32 } = null;
    var pending_match: ?RouteMatch = null;
    var pending_id_field: ?[]const u8 = null; // [worker] // id field_name
    var pending_params: [max_annotation_param_hints]?ParamHint = .{null} ** max_annotation_param_hints;
    var pending_param_count: u8 = 0;

    while (lines.next()) |line| {
        line_num += 1;

        if (prev_annotation) |ann| {
            if (!is_empty(line)) {
                const next_ann = parse_annotation(line, prefix);

                if (next_ann != null or is_comment(line, prefix)) {
                    // Check for `// match` directive between [route] and function body.
                    if (ann.phase == .translate and next_ann == null) {
                        if (parse_match_directive(line, prefix)) |m| {
                            if (pending_match != null) {
                                try stderr.print("error: {s}:{d}: duplicate match directive for [route] .{s}\n", .{ path, line_num, ann.operation });
                                errors += 1;
                            } else if (validate_route_pattern(m.pattern)) |err| {
                                try stderr.print("error: {s}:{d}: invalid route pattern '{s}': {s}\n", .{ path, line_num, m.pattern, err });
                                errors += 1;
                            } else {
                                pending_match = .{
                                    .method = m.method,
                                    .pattern = try allocator.dupe(u8, m.pattern),
                                    .line = line_num,
                                };
                            }
                            continue; // Stay in prev_annotation state, wait for function body.
                        }

                        // `// query <name>` — extract query param into RouteParams.
                        // Only valid after `// match`. Multiple allowed.
                        if (pending_match != null) {
                            if (parse_query_directive(line, prefix)) |name| {
                                if (pending_match.?.query_params.len >= RouteMatch.max_query_params) {
                                    try stderr.print("error: {s}:{d}: too many query params (max {d})\n", .{ path, line_num, RouteMatch.max_query_params });
                                    errors += 1;
                                } else {
                                    pending_match.?.query_params.add(try allocator.dupe(u8, name));
                                }
                                continue;
                            }
                        }
                    }

                    if (ann.phase == .prefetch and next_ann == null) {
                        // `// @param json_array field.subfield` — declares a
                        // body_json_array param for the next query.
                        if (parse_param_directive(line, prefix)) |pd| {
                            if (pending_param_count < pending_params.len) {
                                pending_params[pending_param_count] = .{
                                    .source = .json_array,
                                    .field = pd.field,
                                    .subfield = pd.subfield,
                                };
                                pending_param_count += 1;
                            }
                            continue;
                        }
                    }

                    // `// id field_name` — worker entity id field.
                    if (ann.phase == .worker and next_ann == null) {
                        if (parse_id_directive(line, prefix)) |id_field| {
                            if (pending_id_field != null) {
                                try stderr.print("error: {s}:{d}: duplicate id directive for [worker] .{s}\n", .{ path, line_num, ann.operation });
                                errors += 1;
                            } else {
                                pending_id_field = try allocator.dupe(u8, id_field);
                            }
                            continue;
                        }
                    }

                    // `// match` on non-route phases is an error.
                    if (ann.phase != .translate and ann.phase != .worker and next_ann == null) {
                        if (parse_match_directive(line, prefix) != null) {
                            try stderr.print("error: {s}:{d}: match directive only valid after [route], not [{s}]\n", .{ path, line_num, user_phase_name(ann.phase) });
                            errors += 1;
                            prev_annotation = null;
                            pending_match = null;
                            continue;
                        }
                    }

                    // [handle] without function body = read-only, register it.
                    // Other phases without a body are warnings/errors.
                    if (ann.phase == .execute) {
                        if (!is_valid_operation(ann.operation)) {
                            try stderr.print("error: {s}:{d}: unknown operation '.{s}'\n", .{ path, ann.line, ann.operation });
                            errors += 1;
                        } else {
                            try annotations.append(.{
                                .phase = ann.phase,
                                .operation = try allocator.dupe(u8, ann.operation),
                                .file = try allocator.dupe(u8, path),
                                .line = ann.line,
                                .has_body = false,
                            });
                        }
                    } else if (next_ann == null) {
                        try stderr.print("warning: {s}:{d}: annotation followed by comment, skipping\n", .{ path, ann.line });
                    } else {
                        try stderr.print("error: {s}:{d}: [{s}] .{s} requires a function body\n", .{
                            path, ann.line, user_phase_name(ann.phase), ann.operation,
                        });
                        errors += 1;
                    }
                    prev_annotation = null;
                    if (pending_match) |rm| rm.deinit(allocator);
                    pending_match = null;
                    pending_id_field = null;

                    if (next_ann) |na| {
                        prev_annotation = .{ .phase = na.phase, .operation = na.operation, .line = line_num };
                    }
                } else {
                    // Non-empty, non-comment, non-annotation = code. Register.
                    // All annotated operations are valid — the scanner discovers
                    // the operation set, not validates against a pre-existing enum.
                    {
                        try annotations.append(.{
                            .phase = ann.phase,
                            .operation = try allocator.dupe(u8, ann.operation),
                            .file = try allocator.dupe(u8, path),
                            .line = ann.line,
                            .has_body = true,
                            .route_match = pending_match,
                            .param_hints = pending_params,
                            .param_hint_count = pending_param_count,
                            .id_field = pending_id_field,
                        });
                    }
                    prev_annotation = null;
                    pending_match = null;
                    pending_id_field = null;
                    pending_param_count = 0;
                    pending_params = .{null} ** 4;
                    continue;
                }
            } else {
                continue;
            }
        } else {
            if (parse_annotation(line, prefix)) |ann| {
                prev_annotation = .{ .phase = ann.phase, .operation = ann.operation, .line = line_num };
            } else if (parse_match_directive(line, prefix) != null) {
                // match directive outside any annotation.
                try stderr.print("error: {s}:{d}: match directive without preceding [route] annotation\n", .{ path, line_num });
                errors += 1;
            }
        }
    }

    // Handle annotation at EOF.
    if (prev_annotation) |ann| {
        if (ann.phase == .execute) {
            if (is_valid_operation(ann.operation)) {
                try annotations.append(.{
                    .phase = ann.phase,
                    .operation = try allocator.dupe(u8, ann.operation),
                    .file = try allocator.dupe(u8, path),
                    .line = ann.line,
                    .has_body = false,
                });
            }
        } else {
            try stderr.print("warning: {s}:{d}: annotation at end of file, no code follows\n", .{ path, ann.line });
        }
        // Free pending match if it was duped but never stored on an annotation.
        if (pending_match) |rm| rm.deinit(allocator);
        pending_match = null;
    }

    return errors;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.skip(); // binary name

    const scan_dir = args.next() orelse {
        std.debug.print("Usage: annotation-scanner <directory> [--manifest=<output.json>]\n", .{});
        std.process.exit(1);
    };

    var manifest_path: ?[]const u8 = null;
    var routes_zig_path: ?[]const u8 = null;
    var handlers_zig_path: ?[]const u8 = null;
    var prefetch_zig_path: ?[]const u8 = null;
    var operations_zig_path: ?[]const u8 = null;
    var registry_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--manifest=")) {
            manifest_path = arg[11..];
        } else if (std.mem.startsWith(u8, arg, "--routes-zig=")) {
            routes_zig_path = arg[13..];
        } else if (std.mem.startsWith(u8, arg, "--handlers-zig=")) {
            handlers_zig_path = arg[15..];
        } else if (std.mem.startsWith(u8, arg, "--prefetch-zig=")) {
            prefetch_zig_path = arg[15..];
        } else if (std.mem.startsWith(u8, arg, "--operations-zig=")) {
            operations_zig_path = arg[17..];
        } else if (std.mem.startsWith(u8, arg, "--registry=")) {
            registry_path = arg[11..];
        }
    }

    var annotations = std.ArrayList(Annotation).init(allocator);
    defer annotations.deinit();

    // File records — kept alive in the arena for status extraction pass.
    const FileRecord = struct { path: []const u8, content: []const u8 };
    var files = std.ArrayList(FileRecord).init(allocator);
    defer files.deinit();

    var errors: u32 = 0;
    const stderr = std.io.getStdErr().writer();

    // Scan all files recursively.
    {
        var dir = std.fs.cwd().openDir(scan_dir, .{ .iterate = true }) catch |err| {
            try stderr.print("error: cannot open directory '{s}': {}\n", .{ scan_dir, err });
            std.process.exit(1);
        };
        defer dir.close();

        // Strip trailing slash from scan_dir to avoid double-slash in paths.
        const dir_name = if (scan_dir.len > 0 and scan_dir[scan_dir.len - 1] == '/')
            scan_dir[0 .. scan_dir.len - 1]
        else
            scan_dir;

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const prefix = comment_prefix(entry.basename) orelse continue;

            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_name, entry.path });

            const content = dir.readFileAlloc(allocator, entry.path, 1024 * 1024) catch |err| {
                try stderr.print("error: cannot read '{s}': {}\n", .{ path, err });
                errors += 1;
                continue;
            };

            try files.append(.{ .path = path, .content = content });

            const scan_errors = try scan_file_content(allocator, content, prefix, path, &annotations);
            errors += scan_errors;
        }
    }

    // Check for duplicates.
    for (annotations.items, 0..) |a, i| {
        for (annotations.items[i + 1 ..]) |b| {
            if (a.phase == b.phase and std.mem.eql(u8, a.operation, b.operation)) {
                try stderr.print("error: duplicate handler for [{s}] .{s}\n  --> {s}:{d}\n  --> {s}:{d}\n", .{
                    user_phase_name(a.phase), a.operation, a.file, a.line, b.file, b.line,
                });
                errors += 1;
            }
        }
    }

    // Check for shared route patterns — two operations claiming the same URL.
    // This is valid when handlers disambiguate by query params or body content
    // (e.g., GET /products: list_products vs search_products based on ?q=).
    // Runtime assertion in translate() catches true duplicates (two handlers
    // both claiming the same request). Warn here so developers are aware.
    for (annotations.items, 0..) |a, i| {
        const a_match = a.route_match orelse continue;
        for (annotations.items[i + 1 ..]) |b| {
            const b_match = b.route_match orelse continue;
            if (a_match.method == b_match.method and std.mem.eql(u8, a_match.pattern, b_match.pattern)) {
                try stderr.print("warning: shared route pattern {s} {s} — handlers must disambiguate\n  --> {s}:{d} (.{s})\n  --> {s}:{d} (.{s})\n", .{
                    @tagName(a_match.method), a_match.pattern,
                    a.file, a_match.line, a.operation,
                    b.file, b_match.line, b.operation,
                });
            }
        }
    }

    // Check exhaustiveness — two handler patterns:
    // HTTP operations: [route] + [prefetch] + [handle] + [render]
    // Worker operations: [worker] + [handle] + [render] (no route, no prefetch)
    //
    // An operation is a worker if it has a [worker] annotation.
    // The exhaustiveness check is per-operation, not per-enum-variant,
    // because the scanner discovers operations from annotations.

    // Collect all unique operation names from annotations.
    var all_ops = std.StringHashMap(bool).init(allocator); // value = is_worker
    defer all_ops.deinit();
    for (annotations.items) |ann| {
        if (ann.phase == .worker) {
            try all_ops.put(ann.operation, true);
        } else {
            const existing = all_ops.get(ann.operation);
            if (existing == null) try all_ops.put(ann.operation, false);
        }
    }

    var op_iter = all_ops.iterator();
    while (op_iter.next()) |entry| {
        const op = entry.key_ptr.*;
        const is_worker = entry.value_ptr.*;

        if (is_worker) {
            // Worker: needs [worker] + [handle] + [render].
            const required = [_]Phase{ .worker, .execute, .render };
            for (required) |phase| {
                var found = false;
                for (annotations.items) |ann| {
                    if (ann.phase == phase and std.mem.eql(u8, ann.operation, op)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try stderr.print("error: worker .{s} missing [{s}] phase\n", .{ op, user_phase_name(phase) });
                    errors += 1;
                }
            }
        } else {
            // HTTP: needs [route] + [prefetch] + [handle] + [render].
            const required = [_]Phase{ .translate, .prefetch, .execute, .render };
            for (required) |phase| {
                var found = false;
                for (annotations.items) |ann| {
                    if (ann.phase == phase and std.mem.eql(u8, ann.operation, op)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try stderr.print("error: missing handler for [{s}] .{s}\n", .{ user_phase_name(phase), op });
                    errors += 1;
                }
            }
        }
    }

    // --- Status exhaustiveness check ---
    //
    // For each operation, extract status literals from [handle] body and
    // handled statuses from [render] body. Error if render doesn't cover
    // every status that handle can return. Same check for all languages.
    //
    // op_statuses collects handle statuses for the manifest only —
    // the exhaustiveness check uses local variables directly.
    var op_statuses = std.ArrayList(OperationStatuses).init(allocator);
    defer op_statuses.deinit();

    for (annotations.items) |ann| {
        if (ann.phase != .execute) continue;

        const adapter = find_adapter(ann.file) orelse continue;

        if (!ann.has_body) {
            // Bodyless handle — read-only, only status is ok.
            var ss = StatusSet{};
            ss.add("ok");
            try op_statuses.append(.{ .operation = ann.operation, .statuses = ss });
            continue;
        }

        // File content must exist — stored in the same scan pass that registered this annotation.
        const content = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, ann.file)) break f.content;
        } else unreachable;

        const handle_statuses = extract_statuses_from_handle(content, ann.line, adapter.handle_patterns);
        try op_statuses.append(.{ .operation = ann.operation, .statuses = handle_statuses });

        // Single-status handlers (just ok) don't need a switch in render —
        // there's only one outcome, so the render body handles it implicitly.
        if (handle_statuses.len <= 1) continue;

        // Find the matching [render] annotation for this operation.
        const render_ann = for (annotations.items) |r| {
            if (r.phase == .render and std.mem.eql(u8, r.operation, ann.operation)) break r;
        } else continue; // No render annotation — already caught by exhaustiveness check above.

        if (!render_ann.has_body) continue; // Bodyless render — nothing to check.

        // Render file content must exist — same scan pass stored all file contents.
        const render_content = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, render_ann.file)) break f.content;
        } else unreachable;

        const render_adapter = find_adapter(render_ann.file) orelse continue;
        const render_statuses = extract_statuses_from_body(render_content, render_ann.line, render_adapter.render_patterns);

        // Check: every handle status must be handled in render.
        for (handle_statuses.slice()) |status| {
            if (!has_name(&render_statuses, status)) {
                try stderr.print("error: {s}:{d}: render for .{s} missing status: {s}\n", .{
                    render_ann.file, render_ann.line, ann.operation, status,
                });
                errors += 1;
            }
        }
    }

    // --- Worker handler validation ---
    //
    // Worker operations have three phases: [worker] + [handle] + [render].
    // The [handle] must check ctx.worker_failed (best-effort substring match).
    for (annotations.items) |ann| {
        if (ann.phase != .worker) continue;

        // Find the [handle] annotation for this worker operation.
        const handle_ann = for (annotations.items) |h| {
            if (h.phase == .execute and std.mem.eql(u8, h.operation, ann.operation)) break h;
        } else continue;

        if (!handle_ann.has_body) continue;

        const handle_content = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, handle_ann.file)) break f.content;
        } else continue;

        // Best-effort: check that the handle body references worker_failed.
        const body = SqlStringIterator.init(handle_content, handle_ann.line, '`').body;
        if (std.mem.indexOf(u8, body, "worker_failed") == null) {
            try stderr.print("error: {s}:{d}: [handle] .{s} must check ctx.worker_failed\n", .{
                handle_ann.file, handle_ann.line, ann.operation,
            });
            errors += 1;
        }
    }

    // --- SQL validation ---
    //
    // Extract SQL string literals from prefetch/handle/render bodies.
    // Prefetch and render must be SELECT. Handle must be INSERT/UPDATE/DELETE.
    // Build-time enforcement of read/write separation — same guarantee as
    // Zig-native ReadView/WriteView but via source text scanning.
    for (annotations.items) |ann| {
        if (!ann.has_body) continue;

        const content = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, ann.file)) break f.content;
        } else continue;

        const adapter = find_adapter(ann.file) orelse continue;
        const quote = adapter.sql_quote;

        // Get function body for non-literal SQL detection.
        const body = SqlStringIterator.init(content, ann.line, quote).body;

        switch (ann.phase) {
            .prefetch => {
                var sql_iter = SqlStringIterator.init(content, ann.line, quote);
                var found_sql = false;
                while (sql_iter.next()) |sql| {
                    found_sql = true;
                    if (!sql_starts_with_select(sql)) {
                        try stderr.print("error: {s}:{d}: [prefetch] .{s} SQL must be SELECT: \"{s}...\"\n", .{
                            ann.file, ann.line, ann.operation, sql_preview(sql),
                        });
                        errors += 1;
                    }
                }
                if (!found_sql and body_references_sql(body, .prefetch)) {
                    try stderr.print("warning: {s}:{d}: [prefetch] .{s} has SQL reference but no string literal — cannot validate\n", .{
                        ann.file, ann.line, ann.operation,
                    });
                }

                // Extract prefetch SQL for 1-RT dispatch.
                // If extraction succeeds → 1-RT (framework executes SQL natively).
                // If extraction fails → 2-RT fallback (sidecar declares SQL at runtime).
                // No error, no annotation needed — automatic detection.
                if (found_sql) {
                    if (extract_prefetch_queries(allocator, body, quote, ann.param_hints, ann.param_hint_count)) |pqs| {
                        for (annotations.items) |*a| {
                            if (a.phase == .prefetch and std.mem.eql(u8, a.operation, ann.operation)) {
                                a.prefetch_queries = pqs;
                                break;
                            }
                        }
                    } else {
                        try stderr.print("note: {s}:{d}: [prefetch] .{s} uses 2-RT dispatch (SQL not statically extractable)\n", .{
                            ann.file, ann.line, ann.operation,
                        });
                        // Mark extraction as failed so emitter uses null (2-RT).
                        for (annotations.items) |*a| {
                            if (a.phase == .prefetch and std.mem.eql(u8, a.operation, ann.operation)) {
                                a.extraction_failed = true;
                                break;
                            }
                        }
                    }
                }
            },
            .execute => {
                var sql_iter = SqlStringIterator.init(content, ann.line, quote);
                var found_sql = false;
                while (sql_iter.next()) |sql| {
                    found_sql = true;
                    if (!sql_starts_with_write(sql)) {
                        try stderr.print("error: {s}:{d}: [handle] .{s} SQL must be INSERT/UPDATE/DELETE: \"{s}...\"\n", .{
                            ann.file, ann.line, ann.operation, sql_preview(sql),
                        });
                        errors += 1;
                    }
                }
                if (!found_sql and body_references_sql(body, .execute)) {
                    try stderr.print("warning: {s}:{d}: [handle] .{s} has execute() call but no SQL string literal — cannot validate\n", .{
                        ann.file, ann.line, ann.operation,
                    });
                }
            },
            .render => {
                var sql_iter = SqlStringIterator.init(content, ann.line, quote);
                var found_sql = false;
                while (sql_iter.next()) |sql| {
                    found_sql = true;
                    if (!sql_starts_with_select(sql)) {
                        try stderr.print("error: {s}:{d}: [render] .{s} SQL must be SELECT: \"{s}...\"\n", .{
                            ann.file, ann.line, ann.operation, sql_preview(sql),
                        });
                        errors += 1;
                    }
                }
                if (!found_sql and body_references_sql(body, .render)) {
                    try stderr.print("warning: {s}:{d}: [render] .{s} has SQL reference but no string literal — cannot validate\n", .{
                        ann.file, ann.line, ann.operation,
                    });
                }
            },
            .translate, .worker => {}, // Route/worker have no SQL.
        }
    }

    // Summary.
    const stdout = std.io.getStdOut().writer();
    if (errors > 0) {
        try stderr.print("\n{d} error(s) found.\n", .{errors});
        std.process.exit(1);
    }

    try stdout.print("OK: {d} annotations in {s}/\n", .{ annotations.items.len, scan_dir });

    // Generate operations enum from registry + discovered annotations.
    if (operations_zig_path != null or registry_path != null) {
        try generate_operations(allocator, annotations.items, registry_path, operations_zig_path, stdout);
    }

    // Write manifest if requested.
    if (manifest_path) |out_path| {
        try emit_manifest(allocator, out_path, annotations.items, op_statuses.items);
        try stdout.print("Manifest: {s}\n", .{out_path});
    }

    // Write Zig route table if requested.
    if (routes_zig_path) |out_path| {
        try emit_routes_zig(allocator, out_path, annotations.items);
        try stdout.print("Routes: {s}\n", .{out_path});
    }

    // Write Zig handlers dispatch if requested.
    if (handlers_zig_path) |out_path| {
        try emit_handlers_zig(allocator, out_path, annotations.items);
        try stdout.print("Handlers: {s}\n", .{out_path});
    }

    // Write Zig prefetch specs for 1-RT dispatch if requested.
    if (prefetch_zig_path) |out_path| {
        try emit_prefetch_zig(allocator, out_path, annotations.items);
        try stdout.print("Prefetch: {s}\n", .{out_path});
    }
}

// =====================================================================
// SQL string validation — extract SQL literals, check first keyword
// =====================================================================

/// Iterator over SQL string literals in a function body.
/// Scans for quoted strings that look like SQL — first keyword is
/// a SQL verb (SELECT, INSERT, etc.). Skips status names, HTML, etc.
/// Scoped to the function body (opening `{` to matching `}`).
const SqlStringIterator = struct {
    body: []const u8,
    pos: usize,
    quote: u8,

    fn init(content: []const u8, start_line: u32, quote: u8) SqlStringIterator {
        // Advance to start_line.
        var pos: usize = 0;
        var line: u32 = 1;
        while (pos < content.len and line < start_line) : (pos += 1) {
            if (content[pos] == '\n') line += 1;
        }
        // Find opening brace and extract body by depth.
        // Skip braces inside string literals to avoid misreading
        // strings like "json_col = '{}'" as brace boundaries.
        const brace_start = std.mem.indexOfScalar(u8, content[pos..], '{') orelse
            return .{ .body = "", .pos = 0, .quote = quote };
        const body_start = pos + brace_start + 1;
        var depth: u32 = 1;
        var bpos = body_start;
        var in_string = false;
        var escape_next = false;
        while (bpos < content.len and depth > 0) : (bpos += 1) {
            if (escape_next) {
                escape_next = false;
                continue;
            }
            if (content[bpos] == '\\') {
                escape_next = true;
                continue;
            }
            if (content[bpos] == '"' or content[bpos] == '\'') {
                // Toggle string state. Handles both " and ' quotes.
                // Doesn't track which quote opened — acceptable for
                // brace scanning where we just need to skip string content.
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;
            if (content[bpos] == '{') depth += 1;
            if (content[bpos] == '}') depth -= 1;
        }
        return .{ .body = content[body_start..bpos], .pos = 0, .quote = quote };
    }

    fn next(self: *SqlStringIterator) ?[]const u8 {
        while (self.pos < self.body.len) {
            // Find next quote.
            const start = std.mem.indexOfScalarPos(u8, self.body, self.pos, self.quote) orelse return null;
            self.pos = start + 1;

            // Find closing quote (skip escaped quotes).
            var end = self.pos;
            while (end < self.body.len) : (end += 1) {
                if (self.body[end] == '\\') {
                    end += 1;
                    continue;
                }
                if (self.body[end] == self.quote) break;
            }
            if (end >= self.body.len) return null;

            const str = self.body[self.pos..end];
            self.pos = end + 1;

            // Only return strings that look like SQL — start with a letter
            // and first word is a SQL keyword. Skip status names, HTML, etc.
            const first_word = sql_first_keyword(str) orelse continue;
            if (is_sql_keyword(first_word)) return str;
        }
        return null;
    }
};

/// Extract the first whitespace-delimited word from a SQL string.
fn sql_first_keyword(sql: []const u8) ?[]const u8 {
    // Skip leading whitespace.
    var start: usize = 0;
    while (start < sql.len and (sql[start] == ' ' or sql[start] == '\t' or sql[start] == '\n')) start += 1;
    if (start >= sql.len) return null;

    // Find end of first word.
    var end = start;
    while (end < sql.len and sql[end] != ' ' and sql[end] != '\t' and sql[end] != '\n') end += 1;
    return sql[start..end];
}

/// Check if a word is a known SQL keyword (case-insensitive).
fn is_sql_keyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "SELECT", "INSERT", "UPDATE", "DELETE", "select", "insert", "update", "delete" };
    for (keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(word, kw)) return true;
    }
    return false;
}

fn sql_starts_with_select(sql: []const u8) bool {
    const kw = sql_first_keyword(sql) orelse return false;
    return std.ascii.eqlIgnoreCase(kw, "SELECT");
}

fn sql_starts_with_write(sql: []const u8) bool {
    const kw = sql_first_keyword(sql) orelse return false;
    return std.ascii.eqlIgnoreCase(kw, "INSERT") or
        std.ascii.eqlIgnoreCase(kw, "UPDATE") or
        std.ascii.eqlIgnoreCase(kw, "DELETE");
}

/// Check if a function body references SQL execution without a string literal.
/// Used to warn when SQL is constructed dynamically (scanner can't validate).
fn body_references_sql(body: []const u8, phase: Phase) bool {
    return switch (phase) {
        .execute => std.mem.indexOf(u8, body, "db.execute(") != null,
        .prefetch => std.mem.indexOf(u8, body, "sql:") != null or
            std.mem.indexOf(u8, body, "sql =") != null or
            std.mem.indexOf(u8, body, "query(") != null or
            std.mem.indexOf(u8, body, "query_raw(") != null,
        .render => std.mem.indexOf(u8, body, "sql:") != null or
            std.mem.indexOf(u8, body, "query(") != null or
            std.mem.indexOf(u8, body, "query_raw(") != null,
        .translate, .worker => false,
    };
}

fn sql_preview(sql: []const u8) []const u8 {
    return sql[0..@min(sql.len, 40)];
}

// =====================================================================
// Prefetch SQL extraction — for 1-RT dispatch
// =====================================================================

const max_prefetch_queries = 4;
const max_prefetch_params = 8;

/// Extract prefetch queries from a function body.
/// Scans for `db.query(` and `db.queryAll(` calls, extracts the SQL
/// string and parameter expressions. Returns null if extraction fails
/// (dynamic SQL, unrecognized param pattern, loop-based queries).
fn extract_prefetch_queries(
    allocator: std.mem.Allocator,
    body: []const u8,
    quote: u8,
    param_hints: [max_annotation_param_hints]?ParamHint,
    hint_count: u8,
) ?[]const PrefetchQuery {
    var queries: [max_prefetch_queries]PrefetchQuery = undefined;
    var query_count: usize = 0;

    // Detect loops — if the body contains `for ` or `while ` before a
    // db.query call, the query count is dynamic. Bail out.
    if (std.mem.indexOf(u8, body, "for ") != null or
        std.mem.indexOf(u8, body, "for(") != null)
    {
        return null;
    }

    // Scan for db.query( and db.queryAll( calls.
    var pos: usize = 0;
    while (pos < body.len) {
        // Find next db.query or db.queryAll call.
        const query_call = find_db_query_call(body, pos) orelse break;
        pos = query_call.after_paren;

        if (query_count >= max_prefetch_queries) return null;

        // Extract SQL string — the first quoted argument.
        const sql_start = std.mem.indexOfScalarPos(u8, body, pos, quote) orelse return null;
        var sql_end = sql_start + 1;
        while (sql_end < body.len) : (sql_end += 1) {
            if (body[sql_end] == '\\') { sql_end += 1; continue; }
            if (body[sql_end] == quote) break;
        }
        if (sql_end >= body.len) return null;

        const sql = body[sql_start + 1 .. sql_end];
        if (!sql_starts_with_select(sql)) return null;

        pos = sql_end + 1;

        // Extract params — everything between the SQL closing quote and the
        // closing ) of the db.query() call. Skip the comma after the SQL string.
        const params = extract_param_specs(allocator, body, pos, quote, param_hints, hint_count) orelse return null;
        pos = params.end_pos;

        queries[query_count] = .{
            .sql = sql,
            .mode = query_call.mode,
            .params = params.specs,
            .key = "", // filled in by extract_return_keys
        };
        query_count += 1;
    }

    if (query_count == 0) return &.{};

    // Extract return keys from `return { key1: ..., key2: ... }`.
    const keys = extract_return_keys(body, query_count) orelse return null;
    for (0..query_count) |i| {
        queries[i].key = keys[i];
    }

    return allocator.dupe(PrefetchQuery, queries[0..query_count]) catch return null;
}

const DbQueryCall = struct {
    mode: @TypeOf(@as(PrefetchQuery, undefined).mode),
    after_paren: usize, // position after the opening (
};

/// Find the next `db.query(` or `db.queryAll(` in body starting at pos.
fn find_db_query_call(body: []const u8, start: usize) ?DbQueryCall {
    var pos = start;
    while (pos + 9 < body.len) { // "db.query(" is 9 chars
        if (std.mem.startsWith(u8, body[pos..], "db.queryAll(")) {
            return .{ .mode = .query_all, .after_paren = pos + 12 };
        }
        if (std.mem.startsWith(u8, body[pos..], "db.query(")) {
            return .{ .mode = .query, .after_paren = pos + 9 };
        }
        pos += 1;
    }
    return null;
}

const ExtractedParams = struct {
    specs: []const ParamSpec,
    end_pos: usize,
};

/// Extract parameter specs after the SQL string in a db.query() call.
/// Parses: `, msg.id`, `, msg.body.field`, `, 50`, etc.
/// Returns null if any param is unrecognized.
fn extract_param_specs(
    allocator: std.mem.Allocator,
    body: []const u8,
    start: usize,
    quote: u8,
    param_hints: [max_annotation_param_hints]?ParamHint,
    hint_count: u8,
) ?ExtractedParams {
    var specs: [max_prefetch_params]ParamSpec = undefined;
    var count: usize = 0;
    const pos = start;

    // Find the closing ) — track depth for nested parens.
    var depth: u32 = 1;
    const call_end = blk: {
        var p = pos;
        while (p < body.len) : (p += 1) {
            if (body[p] == quote) {
                // Skip string literals.
                p += 1;
                while (p < body.len and body[p] != quote) : (p += 1) {
                    if (body[p] == '\\') p += 1;
                }
                continue;
            }
            if (body[p] == '(') depth += 1;
            if (body[p] == ')') {
                depth -= 1;
                if (depth == 0) break :blk p;
            }
        }
        return null;
    };

    // Everything between pos and call_end is the param list after SQL.
    const param_text = body[pos..call_end];

    // Split by comma, parse each param expression.
    var it = std.mem.splitScalar(u8, param_text, ',');
    _ = it.next(); // Skip first segment (empty or part of SQL string closing)

    while (it.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t\r\n");
        if (param.len == 0) continue;
        if (count >= max_prefetch_params) return null;

        if (std.mem.eql(u8, param, "msg.id")) {
            specs[count] = .{ .source = .id, .field = "", .int_val = 0 };
        } else if (std.mem.startsWith(u8, param, "msg.body.")) {
            const field = param["msg.body.".len..];
            if (field.len == 0) return null;
            specs[count] = .{ .source = .body_field, .field = field, .int_val = 0 };
        } else if (parse_int_literal(param)) |val| {
            specs[count] = .{ .source = .literal_int, .field = "", .int_val = val };
        } else if (std.mem.startsWith(u8, param, "JSON.stringify(")) {
            // JSON.stringify(...) — use @param hint to determine the source.
            if (count < hint_count) {
                if (param_hints[count]) |hint| {
                    switch (hint.source) {
                        .json_array => {
                            specs[count] = .{ .source = .body_json_array, .field = hint.field, .subfield = hint.subfield, .int_val = 0 };
                        },
                    }
                } else return null;
            } else return null;
        } else {
            // Unrecognized param pattern — extraction fails.
            return null;
        }
        count += 1;
    }

    return .{
        .specs = allocator.dupe(ParamSpec, specs[0..count]) catch return null,
        .end_pos = call_end + 1,
    };
}

/// Parse an integer literal from a string (e.g., "50", "100").
fn parse_int_literal(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var val: i64 = 0;
    var neg = false;
    var i: usize = 0;
    if (s[0] == '-') { neg = true; i = 1; }
    if (i >= s.len) return null;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return null;
        val = val * 10 + @as(i64, s[i] - '0');
    }
    return if (neg) -val else val;
}

/// Extract return key names from `return { key1: ..., key2: ... }`.
/// Returns an array of key names in declaration order.
fn extract_return_keys(body: []const u8, expected_count: usize) ?[max_prefetch_queries][]const u8 {
    var keys: [max_prefetch_queries][]const u8 = .{""} ** max_prefetch_queries;
    var count: usize = 0;

    // Find `return {` or `return({` pattern.
    const return_pos = std.mem.indexOf(u8, body, "return ") orelse
        std.mem.indexOf(u8, body, "return{") orelse
        return null;
    var pos = return_pos + 7; // skip "return "
    // Skip whitespace and optional `(`.
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '(' or body[pos] == '\n')) pos += 1;
    if (pos >= body.len or body[pos] != '{') return null;
    pos += 1; // skip `{`

    // Parse keys: `key1: expr, key2: expr`.
    while (pos < body.len and count < max_prefetch_queries) {
        // Skip whitespace.
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t' or body[pos] == '\n' or body[pos] == '\r')) pos += 1;
        if (pos >= body.len or body[pos] == '}') break;

        // Read identifier — stop at `:`, `,`, `}`, space, or newline.
        const key_start = pos;
        while (pos < body.len and body[pos] != ':' and body[pos] != ',' and
            body[pos] != '}' and body[pos] != ' ' and body[pos] != '\n' and body[pos] != '\r') pos += 1;
        if (pos == key_start) return null;

        keys[count] = body[key_start..pos];
        count += 1;

        // Skip whitespace after key.
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) pos += 1;

        if (pos < body.len and body[pos] == ':') {
            // `key: expr` — skip past the value expression.
            pos += 1;
            var depth2: u32 = 0;
            while (pos < body.len) : (pos += 1) {
                if (body[pos] == '(' or body[pos] == '[') depth2 += 1;
                if (body[pos] == ')' or body[pos] == ']') {
                    if (depth2 > 0) depth2 -= 1;
                }
                if (depth2 == 0 and (body[pos] == ',' or body[pos] == '}')) break;
            }
        }
        // Shorthand `{ key }` or `{ key, key2 }` — no `:`, already at `,` or `}`.
        if (pos < body.len and body[pos] == ',') pos += 1;
    }

    if (count != expected_count) return null;
    return keys;
}

fn has_name(ss: *const StatusSet, name: []const u8) bool {
    for (ss.slice()) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

// =====================================================================
// Operations generation — registry + enum file
// =====================================================================

/// Registry entry: operation name → u8 value.
const RegistryEntry = struct {
    name: []const u8,
    value: u8,
};

/// Generate operations.generated.zig from the registry + discovered annotations.
/// 1. Read operations.json (if exists) for stable u8 values.
/// 2. Collect unique operation names from annotations.
/// 3. Assign u8 values to new operations (next available).
/// 4. Write operations.generated.zig (the enum).
/// 5. Write updated operations.json.
fn generate_operations(
    allocator: std.mem.Allocator,
    annotations: []const Annotation,
    registry_path: ?[]const u8,
    operations_zig_path: ?[]const u8,
    stdout: anytype,
) !void {
    // Collect unique operation names from annotations (excluding worker phase — those are worker function names, not operations).
    var op_set = std.StringHashMap(void).init(allocator);
    defer op_set.deinit();
    for (annotations) |ann| {
        if (ann.phase == .worker) {
            // Worker operations are discovered from [handle]/[render]
            // annotations on the same operation name. The [worker] phase
            // itself uses the same operation name.
            try op_set.put(ann.operation, {});
            continue;
        }
        try op_set.put(ann.operation, {});
    }

    // Load existing registry.
    var registry = std.ArrayList(RegistryEntry).init(allocator);
    defer registry.deinit();
    var next_value: u8 = 1; // 0 is reserved for root

    if (registry_path) |path| {
        const reg_content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch "";
        if (reg_content.len > 0) {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reg_content, .{});
            defer parsed.deinit();
            if (parsed.value == .object) {
                var it = parsed.value.object.iterator();
                while (it.next()) |entry| {
                    const val: u8 = @intCast(entry.value_ptr.integer);
                    try registry.append(.{ .name = try allocator.dupe(u8, entry.key_ptr.*), .value = val });
                    if (val >= next_value) next_value = val + 1;
                }
            }
        }
    }

    // Ensure root is in registry.
    var has_root = false;
    for (registry.items) |r| {
        if (std.mem.eql(u8, r.name, "root")) { has_root = true; break; }
    }
    if (!has_root) {
        try registry.append(.{ .name = "root", .value = 0 });
    }

    // Add new operations from annotations that aren't in the registry.
    var op_iter = op_set.iterator();
    while (op_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        var found = false;
        for (registry.items) |r| {
            if (std.mem.eql(u8, r.name, name)) { found = true; break; }
        }
        if (!found) {
            try registry.append(.{ .name = try allocator.dupe(u8, name), .value = next_value });
            try stdout.print("note: new operation '.{s}' assigned value {d}\n", .{ name, next_value });
            next_value += 1;
        }
    }

    // Sort registry by value for deterministic output.
    std.mem.sort(RegistryEntry, registry.items, {}, struct {
        fn less(_: void, a: RegistryEntry, b: RegistryEntry) bool {
            return a.value < b.value;
        }
    }.less);

    // Write operations.generated.zig.
    if (operations_zig_path) |path| {
        var buf = std.ArrayList(u8).init(allocator);
        const w = buf.writer();

        try w.writeAll(
            \\// Auto-generated from operations.json by annotation scanner — do not edit.
            \\//
            \\// The Operation enum is the single set of domain operations. Values are
            \\// stable across builds (WAL compatibility). New operations are assigned
            \\// the next available value by the scanner.
            \\
            \\const std = @import("std");
            \\
            \\pub const Operation = enum(u8) {
            \\
        );
        for (registry.items) |r| {
            try w.print("    {s} = {d},\n", .{ r.name, r.value });
        }
        try w.writeAll(
            \\
            \\    pub fn is_mutation(op: Operation) bool {
            \\        return switch (op) {
            \\            .root,
            \\            .page_load_dashboard, .page_load_login,
            \\            .logout,
            \\            .list_products, .list_collections, .list_orders,
            \\            .get_product, .get_collection, .get_order,
            \\            .get_product_inventory, .search_products,
            \\            => false,
            \\            else => true,
            \\        };
            \\    }
            \\
            \\    pub fn from_string(name: []const u8) ?Operation {
            \\        inline for (@typeInfo(Operation).@"enum".fields) |f| {
            \\            if (std.mem.eql(u8, f.name, name)) return @enumFromInt(f.value);
            \\        }
            \\        return null;
            \\    }
            \\};
            \\
        );

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(buf.items);
        try stdout.print("Operations: {s}\n", .{path});
    }

    // Write updated registry.
    if (registry_path) |path| {
        var buf = std.ArrayList(u8).init(allocator);
        const w = buf.writer();
        try w.writeAll("{\n");
        for (registry.items, 0..) |r, i| {
            if (i > 0) try w.writeAll(",\n");
            try w.print("  \"{s}\": {d}", .{ r.name, r.value });
        }
        try w.writeAll("\n}\n");

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(buf.items);
    }
}

/// Write the annotation manifest as JSON.
/// This is the contract between the scanner and language adapters.
/// Annotations are sorted by file + line for deterministic output
/// regardless of filesystem directory walk order.
fn emit_manifest(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    annotations: []const Annotation,
    op_statuses: []const OperationStatuses,
) !void {
    // Sort for deterministic output — filesystem walk order varies.
    const sorted = try allocator.dupe(Annotation, annotations);
    std.mem.sort(Annotation, sorted, {}, struct {
        fn less(_: void, a: Annotation, b: Annotation) bool {
            const file_cmp = std.mem.order(u8, a.file, b.file);
            if (file_cmp != .eq) return file_cmp == .lt;
            return a.line < b.line;
        }
    }.less);

    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll("{\n  \"annotations\": [\n");
    for (sorted, 0..) |ann, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.print("    {{ \"phase\": \"{s}\", \"operation\": \"{s}\", \"file\": \"{s}\", \"line\": {d}, \"has_body\": {s}", .{
            @tagName(ann.phase), ann.operation, ann.file, ann.line, if (ann.has_body) "true" else "false",
        });

        // Include route match for translate (route) phase annotations.
        if (ann.route_match) |rm| {
            try w.print(", \"route_match\": {{ \"method\": \"{s}\", \"pattern\": \"{s}\"", .{
                @tagName(rm.method), rm.pattern,
            });
            if (rm.query_params.len > 0) {
                try w.writeAll(", \"query_params\": [");
                for (rm.query_params.names[0..rm.query_params.len], 0..) |name, qi| {
                    if (qi > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{name});
                }
                try w.writeAll("]");
            }
            try w.writeAll(" }");
        }

        // Include id field for worker phase annotations.
        if (ann.id_field) |id_field| {
            try w.print(", \"id_field\": \"{s}\"", .{id_field});
        }

        // Include statuses for execute (handle) phase annotations.
        if (ann.phase == .execute) {
            for (op_statuses) |os| {
                if (std.mem.eql(u8, os.operation, ann.operation)) {
                    try w.writeAll(", \"statuses\": [");
                    for (os.statuses.slice(), 0..) |s, j| {
                        if (j > 0) try w.writeAll(", ");
                        try w.print("\"{s}\"", .{s});
                    }
                    try w.writeAll("]");
                    break;
                }
            }
        }

        try w.writeAll(" }");
    }
    try w.writeAll("\n  ]\n}\n");

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Emit generated/routes.generated.zig — comptime route table from annotations.
/// Sorted by specificity: literal segments before param segments, longer patterns
/// before shorter. This is the single source of truth for Zig routing — handlers
/// no longer declare route_method/route_pattern constants.
fn emit_routes_zig(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    annotations: []const Annotation,
) !void {
    // Collect route entries from translate-phase annotations.
    const RouteEntry = struct {
        operation: []const u8,
        method: []const u8,
        pattern: []const u8,
        file: []const u8,
        query_params: RouteMatch.QueryParams,
    };
    var routes = std.ArrayList(RouteEntry).init(allocator);
    for (annotations) |ann| {
        if (ann.phase != .translate) continue;
        const rm = ann.route_match orelse continue;
        try routes.append(.{
            .operation = ann.operation,
            .method = @tagName(rm.method),
            .pattern = rm.pattern,
            .file = ann.file,
            .query_params = rm.query_params,
        });
    }

    // Sort by specificity: more specific patterns first.
    // Within same specificity, sort by operation name for determinism.
    const SortCtx = struct {
        fn specificity(pattern: []const u8) u32 {
            // Count literal segments (non-param). More literals = more specific.
            if (std.mem.eql(u8, pattern, "/")) return 0;
            var score: u32 = 0;
            var rest: []const u8 = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
            while (rest.len > 0) {
                const slash = std.mem.indexOfScalar(u8, rest, '/');
                const seg = if (slash) |s| rest[0..s] else rest;
                if (seg.len > 0 and seg[0] != ':') score += 1;
                score += 1; // total segment count for tiebreaking
                rest = if (slash) |s| rest[s + 1 ..] else "";
            }
            return score;
        }

        fn less_than(_: void, a: RouteEntry, b: RouteEntry) bool {
            const sa = specificity(a.pattern);
            const sb = specificity(b.pattern);
            if (sa != sb) return sa > sb; // more specific first
            return std.mem.order(u8, a.operation, b.operation) == .lt;
        }
    };
    std.mem.sort(RouteEntry, routes.items, {}, SortCtx.less_than);

    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    try w.writeAll(
        \\// Auto-generated by annotation scanner — do not edit.
        \\//
        \\// Comptime route table from // match directives. Single source of truth
        \\// for Zig routing. Handlers declare routes via annotations only.
        \\// Sorted by specificity: literal segments before param, longer before shorter.
        \\
        \\const message = @import("../message.zig");
        \\const http = @import("../framework/http.zig");
        \\
        \\pub const Route = struct {
        \\    operation: message.Operation,
        \\    method: http.Method,
        \\    pattern: []const u8,
        \\    query_params: []const []const u8,
        \\    handler: type,
        \\};
        \\
        \\pub const routes = [_]Route{
        \\
    );

    for (routes.items) |route| {
        try w.print("    .{{ .operation = .{s}, .method = .{s}, .pattern = \"{s}\", .query_params = &.{{", .{
            route.operation, route.method, route.pattern,
        });
        for (route.query_params.names[0..route.query_params.len], 0..) |name, qi| {
            if (qi > 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{name});
        }
        // Handler module import — relative to generated/ directory.
        try w.print("}}, .handler = @import(\"../{s}\") }},\n", .{route.file});
    }

    try w.writeAll(
        \\};
        \\
        \\// Comptime assertions — pair with scanner's validation.
        \\comptime {
        \\    const enums = @import("std").enums;
        \\
        \\    // Assert: every Operation has at least one route entry.
        \\    // If a handler file exists without a // match annotation, this catches it.
        \\    for (enums.values(message.Operation)) |op| {
        \\        // .root is the zero-valued sentinel in message.Operation — it's not
        \\        // a real operation and has no handler. If more sentinels are added,
        \\        // they must be listed here.
        \\        if (op == .root) continue;
        \\        // Worker completion operations have [route] but no // match —
        \\        // they are triggered by worker completion, not HTTP requests.
        \\        if (is_completion_operation(op)) continue;
        \\        var found = false;
        \\        for (routes) |r| {
        \\            if (r.operation == op) { found = true; break; }
        \\        }
        \\        if (!found) @compileError("no // match annotation for operation: " ++ @tagName(op));
        \\    }
        \\
        \\    // Assert: path params + query params fit in RouteParams for every route.
        \\    const parse = @import("../framework/parse.zig");
        \\    for (routes) |r| {
        \\        const path_params = parse.count_params(r.pattern);
        \\        const total = path_params + r.query_params.len;
        \\        if (total > parse.max_route_params) {
        \\            @compileError("route " ++ r.pattern ++ " has too many params (path + query)");
        \\        }
        \\    }
        \\
        \\    // Assert: Method enum values match the cross-language contract
        \\    // (method_vectors.json). If someone adds/reorders enum variants,
        \\    // this fires — update method_vectors.json and re-verify all languages.
        \\    const assert = @import("std").debug.assert;
        \\    assert(@intFromEnum(http.Method.get) == 0);
        \\    assert(@intFromEnum(http.Method.put) == 1);
        \\    assert(@intFromEnum(http.Method.post) == 2);
        \\    assert(@intFromEnum(http.Method.delete) == 3);
        \\    assert(@typeInfo(http.Method).@"enum".fields.len == 4);
        \\}
        \\
        \\// Shared route patterns are allowed — handlers disambiguate at runtime
        \\// (e.g., GET /products: list vs search based on ?q= query param).
        \\// Runtime assertion in translate() catches true duplicates (two handlers
        \\// both claiming the same request). This is correct REST design: filtering
        \\// a collection by query param is the same endpoint, not a sub-resource.
        \\
    );

    // Worker operations have no `// match` — they are triggered by worker
    // completion, not HTTP requests. The routes.zig comptime check uses
    // handlers.generated.zig:is_sidecar_operation to skip them automatically.

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

fn emit_handlers_zig(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    annotations: []const Annotation,
) !void {
    // Collect unique operations with their handler file.
    const OpInfo = struct {
        operation: []const u8,
        file: []const u8,
        is_zig: bool,
    };
    var ops = std.ArrayList(OpInfo).init(allocator);
    defer ops.deinit();

    for (annotations) |ann| {
        if (ann.phase != .translate) continue; // one entry per operation
        const is_zig = std.mem.endsWith(u8, ann.file, ".zig");
        try ops.append(.{
            .operation = ann.operation,
            .file = ann.file,
            .is_zig = is_zig,
        });
    }

    // Don't sort — we emit in Operation enum declaration order below
    // using valid_operations (which preserves enum field order).

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll(
        \\// Auto-generated by annotation scanner — do not edit.
        \\//
        \\// Handler dispatch and PrefetchCache for the unified pipeline.
        \\// Zig handlers dispatch directly. Sidecar handlers dispatch via
        \\// CALL/RESULT protocol. Cache uses void for sidecar operations.
        \\
        \\const std = @import("std");
        \\const message = @import("../message.zig");
        \\const state_machine = @import("../state_machine.zig");
        \\
        \\const Operation = message.Operation;
        \\const Message = message.Message;
        \\const Status = message.Status;
        \\
        \\
    );

    // PrefetchCache union — typed Prefetch for Zig, void for sidecar.
    // Fields emitted in Operation enum declaration order (required by Zig).
    try w.writeAll(
        \\/// PrefetchCache — tagged union of handler Prefetch types.
        \\/// Zig handlers have typed Prefetch structs. Sidecar handlers
        \\/// use void — data lives on the sidecar client, not in the cache.
        \\pub const PrefetchCache = union(Operation) {
        \\    root: void,
        \\
    );
    for (valid_operations) |op_name| {
        if (std.mem.eql(u8, op_name, "root")) continue;
        // Find in ops list.
        const info = for (ops.items) |op| {
            if (std.mem.eql(u8, op.operation, op_name)) break op;
        } else null;

        if (info) |op| {
            if (op.is_zig) {
                try w.print("    {s}: @import(\"../{s}\").Prefetch,\n", .{ op_name, op.file });
            } else {
                try w.print("    {s}: void,\n", .{op_name});
            }
        } else {
            // Operation exists in enum but no handler scanned — shouldn't
            // happen if scanner validates, but emit void as safety.
            try w.print("    {s}: void,\n", .{op_name});
        }
    }
    try w.writeAll(
        \\};
        \\
        \\
    );

    // dispatch_prefetch
    try w.writeAll(
        \\/// Phase 1: dispatch to handler.prefetch().
        \\pub fn dispatch_prefetch(ro: anytype, msg: *const Message) ?PrefetchCache {
        \\    return switch (msg.operation) {
        \\        .root => unreachable,
        \\
    );
    for (valid_operations) |op_name| {
        if (std.mem.eql(u8, op_name, "root")) continue;
        const info = for (ops.items) |op| {
            if (std.mem.eql(u8, op.operation, op_name)) break op;
        } else null;
        if (info) |op| {
            if (op.is_zig) {
                try w.print("        .{s} => prefetch_one(@import(\"../{s}\"), .{s}, ro, msg),\n", .{ op_name, op.file, op_name });
            } else {
                try w.print("        .{s} => null,\n", .{op_name});
            }
        } else {
            try w.print("        .{s} => null,\n", .{op_name});
        }
    }
    try w.writeAll(
        \\    };
        \\}
        \\
        \\
    );

    // dispatch_execute
    try w.writeAll(
        \\/// Phase 2: dispatch to handler.handle().
        \\pub fn dispatch_execute(
        \\    cache: PrefetchCache,
        \\    msg: Message,
        \\    fw: anytype,
        \\    db: anytype,
        \\) state_machine.HandleResult {
        \\    return switch (msg.operation) {
        \\        .root => unreachable,
        \\
    );
    for (valid_operations) |op_name| {
        if (std.mem.eql(u8, op_name, "root")) continue;
        const info = for (ops.items) |op| {
            if (std.mem.eql(u8, op.operation, op_name)) break op;
        } else null;
        if (info) |op| {
            if (op.is_zig) {
                try w.print("        .{s} => execute_one(@import(\"../{s}\"), .{s}, cache, msg, fw, db),\n", .{ op_name, op.file, op_name });
            } else {
                try w.print("        .{s} => unreachable,\n", .{op_name});
            }
        } else {
            try w.print("        .{s} => unreachable,\n", .{op_name});
        }
    }
    try w.writeAll(
        \\    };
        \\}
        \\
        \\
    );

    // dispatch_render
    try w.writeAll(
        \\/// Phase 3: dispatch to handler.render().
        \\pub fn dispatch_render(
        \\    cache: PrefetchCache,
        \\    operation: Operation,
        \\    status: Status,
        \\    fw: anytype,
        \\    render_buf: []u8,
        \\    storage: anytype,
        \\) []const u8 {
        \\    return switch (operation) {
        \\        .root => unreachable,
        \\
    );
    for (valid_operations) |op_name| {
        if (std.mem.eql(u8, op_name, "root")) continue;
        const info = for (ops.items) |op| {
            if (std.mem.eql(u8, op.operation, op_name)) break op;
        } else null;
        if (info) |op| {
            if (op.is_zig) {
                try w.print("        .{s} => render_one(@import(\"../{s}\"), .{s}, cache, status, fw, render_buf, storage),\n", .{ op_name, op.file, op_name });
            } else {
                try w.print("        .{s} => unreachable,\n", .{op_name});
            }
        } else {
            try w.print("        .{s} => unreachable,\n", .{op_name});
        }
    }
    try w.writeAll(
        \\    };
        \\}
        \\
        \\
    );

    // is_sidecar_operation — comptime function
    try w.writeAll(
        \\/// Returns true if the operation is handled by a sidecar runtime.
        \\/// Determined at scan time from file extension (.zig = native, others = sidecar).
        \\pub fn is_sidecar_operation(op: Operation) bool {
        \\    return switch (op) {
        \\        .root => false,
        \\
    );
    for (valid_operations) |op_name| {
        if (std.mem.eql(u8, op_name, "root")) continue;
        const info = for (ops.items) |op| {
            if (std.mem.eql(u8, op.operation, op_name)) break op;
        } else null;
        const is_sidecar = if (info) |op| !op.is_zig else false;
        try w.print("        .{s} => {},\n", .{ op_name, is_sidecar });
    }
    try w.writeAll(
        \\    };
        \\}
        \\
        \\
    );

    // Helper functions — generic wrappers that call handler modules.
    try w.writeAll(
        \\// --- Helpers ---
        \\
        \\fn prefetch_one(comptime H: type, comptime op: Operation, ro: anytype, msg: *const Message) ?PrefetchCache {
        \\    const result = H.prefetch(ro, msg) orelse return null;
        \\    return @unionInit(PrefetchCache, @tagName(op), result);
        \\}
        \\
        \\fn execute_one(
        \\    comptime H: type,
        \\    comptime op: Operation,
        \\    cache: PrefetchCache,
        \\    msg: Message,
        \\    fw: anytype,
        \\    db: anytype,
        \\) state_machine.HandleResult {
        \\    const prefetched = @field(cache, @tagName(op));
        \\    const ctx = H.Context{
        \\        .prefetched = prefetched,
        \\        .body = if (H.Context.BodyType == void) {} else msg.body_as(H.Context.BodyType),
        \\        .fw = fw,
        \\        .render_buf = &.{},
        \\    };
        \\    return H.handle(ctx, db);
        \\}
        \\
        \\fn render_one(
        \\    comptime H: type,
        \\    comptime op: Operation,
        \\    cache: PrefetchCache,
        \\    status: Status,
        \\    fw: anytype,
        \\    render_buf: []u8,
        \\    storage: anytype,
        \\) []const u8 {
        \\    const prefetched = @field(cache, @tagName(op));
        \\    const HandlerStatus = H.Context.StatusType;
        \\    const ctx = H.Context{
        \\        .prefetched = prefetched,
        \\        .body = if (H.Context.BodyType == void) {} else undefined,
        \\        .fw = fw,
        \\        .render_buf = render_buf,
        \\        .status = map_status(HandlerStatus, status),
        \\    };
        \\    const render_fn_info = @typeInfo(@TypeOf(H.render)).@"fn";
        \\    if (render_fn_info.params.len >= 2) {
        \\        return H.render(ctx, storage);
        \\    } else {
        \\        return H.render(ctx);
        \\    }
        \\}
        \\
        \\fn map_status(comptime HandlerStatus: type, status: Status) HandlerStatus {
        \\    if (HandlerStatus == Status) return status;
        \\    const status_name = @tagName(status);
        \\    inline for (@typeInfo(HandlerStatus).@"enum".fields) |f| {
        \\        if (std.mem.eql(u8, f.name, status_name)) {
        \\            return @enumFromInt(f.value);
        \\        }
        \\    }
        \\    unreachable;
        \\}
        \\
    );

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Emit prefetch.generated.zig — comptime prefetch specs for 1-RT dispatch.
/// Each operation maps to either a PrefetchSpec (queries to execute natively)
/// or null (dynamic prefetch, use 4-RT fallback).
fn emit_prefetch_zig(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    annotations: []const Annotation,
) !void {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll(
        \\// Auto-generated by annotation scanner — do not edit.
        \\//
        \\// Prefetch SQL specs for 1-RT sidecar dispatch. The framework
        \\// executes these queries natively instead of calling the sidecar
        \\// for the prefetch phase. Operations with `null` use 2-RT fallback
        \\// (SQL not statically extractable, or operations without prefetch).
        \\
        \\const protocol = @import("../protocol.zig");
        \\
        \\pub const ParamSource = enum { none, id, body_field, literal_int, body_json_array };
        \\
        \\pub const ParamSpec = struct {
        \\    source: ParamSource,
        \\    field: []const u8,
        \\    subfield: []const u8 = "",
        \\    int_val: i64,
        \\};
        \\
        \\pub const QuerySpec = struct {
        \\    sql: []const u8,
        \\    mode: protocol.QueryMode,
        \\    params: []const ParamSpec,
        \\    key: []const u8,
        \\};
        \\
        \\pub const PrefetchSpec = struct {
        \\    queries: []const QuerySpec,
        \\};
        \\
        \\
    );

    // Emit specs indexed by enum VALUE (not declaration order).
    // The Operation enum may have non-sequential values, so we
    // compute the max value at comptime and emit a fixed-size array.
    const max_enum_value = comptime blk: {
        const fields = @typeInfo(Operation).@"enum".fields;
        var max: usize = 0;
        for (fields) |f| {
            if (f.value > max) max = f.value;
        }
        break :blk max;
    };
    const spec_count = max_enum_value + 1;

    // Build a comptime map: enum value → operation name.
    const enum_names = comptime blk: {
        var names: [spec_count]?[]const u8 = .{null} ** spec_count;
        for (@typeInfo(Operation).@"enum".fields) |f| {
            names[f.value] = f.name;
        }
        break :blk names;
    };

    try w.print("pub const specs = [{d}]?PrefetchSpec{{\n", .{spec_count});

    for (enum_names, 0..) |maybe_name, val| {
        if (maybe_name == null) {
            try w.print("    null, // unused value {d}\n", .{val});
            continue;
        }
        if (std.mem.eql(u8, maybe_name.?, "root")) {
            try w.print("    null, // .root\n", .{});
            continue;
        }

        const name = maybe_name.?;
        const prefetch_ann: ?Annotation = for (annotations) |ann| {
            if (ann.phase == .prefetch and std.mem.eql(u8, ann.operation, name)) break ann;
        } else null;

        if (prefetch_ann) |ann| {
            if (ann.extraction_failed) {
                // Extraction failed — use 2-RT.
                try w.print("    null, // .{s} — 2-RT\n", .{name});
                continue;
            }
            if (ann.prefetch_queries.len == 0) {
                // No SQL queries — 1-RT with no prefetch (handle_render only).
                try w.print("    .{{ .queries = &.{{}} }}, // .{s} — no SQL\n", .{name});
                continue;
            }

            // Emit the spec.
            try w.print("    .{{ .queries = &.{{\n", .{});
            for (ann.prefetch_queries) |q| {
                try w.print("        .{{\n", .{});
                try w.print("            .sql = \"{s}\",\n", .{q.sql});
                try w.print("            .mode = .{s},\n", .{@tagName(q.mode)});

                // Params.
                try w.print("            .params = &.{{", .{});
                for (q.params, 0..) |p, pi| {
                    if (pi > 0) try w.print(", ", .{});
                    switch (p.source) {
                        .id => try w.print(".{{ .source = .id, .field = \"\", .int_val = 0 }}", .{}),
                        .body_field => try w.print(".{{ .source = .body_field, .field = \"{s}\", .int_val = 0 }}", .{p.field}),
                        .literal_int => try w.print(".{{ .source = .literal_int, .field = \"\", .int_val = {d} }}", .{p.int_val}),
                        .body_json_array => try w.print(".{{ .source = .body_json_array, .field = \"{s}\", .subfield = \"{s}\", .int_val = 0 }}", .{ p.field, p.subfield }),
                    }
                }
                try w.print("}},\n", .{});

                try w.print("            .key = \"{s}\",\n", .{q.key});
                try w.print("        }},\n", .{});
            }
            try w.print("    }} }}, // .{s}\n", .{name});
        } else {
            // No prefetch annotation — some operations have none (e.g., logout).
            // Emit a spec with no queries (framework skips prefetch).
            try w.print("    .{{ .queries = &.{{}} }}, // .{s} — no prefetch\n", .{name});
        }
    }

    try w.print("}};\n\n", .{});
    try w.print("pub const operation_count = {d};\n", .{spec_count});

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// =====================================================================
// Tests
// =====================================================================

test "parse_annotation valid" {
    const result = parse_annotation("// [handle] .create_product", "//");
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
    const result = parse_annotation("# [route] .list_products", "#");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .translate);
    try std.testing.expect(std.mem.eql(u8, result.?.operation, "list_products"));
}

test "parse_annotation all user-facing phases" {
    const route = parse_annotation("// [route] .create_product", "//");
    try std.testing.expect(route != null);
    try std.testing.expectEqual(route.?.phase, .translate);

    const prefetch = parse_annotation("// [prefetch] .create_product", "//");
    try std.testing.expect(prefetch != null);
    try std.testing.expectEqual(prefetch.?.phase, .prefetch);

    const handle = parse_annotation("// [handle] .get_product", "//");
    try std.testing.expect(handle != null);
    try std.testing.expectEqual(handle.?.phase, .execute);

    const render = parse_annotation("// [render] .list_products", "//");
    try std.testing.expect(render != null);
    try std.testing.expectEqual(render.?.phase, .render);
}

test "parse_annotation rejects internal prefetch name" {
    // "prefetch" is a valid user-facing name (unlike translate/execute).
    const result = parse_annotation("// [prefetch] .get_product", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.phase, .prefetch);
}

test "user_phase_name round-trips" {
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.translate), "route"));
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.prefetch), "prefetch"));
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.execute), "handle"));
    try std.testing.expect(std.mem.eql(u8, user_phase_name(.render), "render"));
}

test "parse_annotation rejects internal phase names" {
    // Internal names belong to Zig framework, not handler annotations.
    try std.testing.expect(parse_annotation("// [translate] .foo", "//") == null);
    try std.testing.expect(parse_annotation("// [execute] .foo", "//") == null);
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

// --- parse_match_directive tests ---

test "match: valid GET" {
    const result = parse_match_directive("// match GET /products/:id", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
    try std.testing.expect(std.mem.eql(u8, result.?.pattern, "/products/:id"));
}

test "match: valid POST with sub-resource" {
    const result = parse_match_directive("// match POST /orders/:id/complete", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .post);
    try std.testing.expect(std.mem.eql(u8, result.?.pattern, "/orders/:id/complete"));
}

test "match: valid DELETE" {
    const result = parse_match_directive("// match DELETE /products/:id", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .delete);
}

test "match: case insensitive method" {
    const result = parse_match_directive("// match get /products", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
}

test "match: root path" {
    const result = parse_match_directive("// match GET /", "//");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?.pattern, "/"));
}

test "match: python style" {
    const result = parse_match_directive("# match GET /products/:id", "#");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
}

test "match: rejects missing method" {
    try std.testing.expect(parse_match_directive("// match /products/:id", "//") == null);
}

test "match: rejects invalid method" {
    try std.testing.expect(parse_match_directive("// match TRACE /products", "//") == null);
}

test "match: rejects missing path" {
    try std.testing.expect(parse_match_directive("// match GET", "//") == null);
}

test "match: rejects path without leading slash" {
    try std.testing.expect(parse_match_directive("// match GET products/:id", "//") == null);
}

test "match: rejects non-match comment" {
    try std.testing.expect(parse_match_directive("// some comment", "//") == null);
}

test "match: rejects plain code" {
    try std.testing.expect(parse_match_directive("pub fn route() void {}", "//") == null);
}

test "match: leading whitespace" {
    const result = parse_match_directive("  // match GET /products", "//");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.method, .get);
}

// --- parse_query_directive tests ---

test "query: valid name" {
    const result = parse_query_directive("// query q", "//");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "q"));
}

test "query: underscore name" {
    const result = parse_query_directive("// query page_size", "//");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "page_size"));
}

test "query: leading whitespace" {
    const result = parse_query_directive("  // query q", "//");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "q"));
}

test "query: trailing whitespace" {
    const result = parse_query_directive("// query q  ", "//");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "q"));
}

test "query: python comment prefix" {
    const result = parse_query_directive("# query q", "#");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.eql(u8, result.?, "q"));
}

test "query: rejects empty name" {
    try std.testing.expect(parse_query_directive("// query ", "//") == null);
}

test "query: rejects hyphenated name" {
    try std.testing.expect(parse_query_directive("// query q-name", "//") == null);
}

test "query: rejects dotted name" {
    try std.testing.expect(parse_query_directive("// query q.name", "//") == null);
}

test "query: rejects non-query comment" {
    try std.testing.expect(parse_query_directive("// some comment", "//") == null);
}

test "query: rejects match directive" {
    try std.testing.expect(parse_query_directive("// match GET /products", "//") == null);
}

test "query: rejects wrong prefix" {
    try std.testing.expect(parse_query_directive("# query q", "//") == null);
}

// --- validate_route_pattern tests ---

test "pattern: valid paths" {
    try std.testing.expect(validate_route_pattern("/") == null);
    try std.testing.expect(validate_route_pattern("/products") == null);
    try std.testing.expect(validate_route_pattern("/products/:id") == null);
    try std.testing.expect(validate_route_pattern("/orders/:id/complete") == null);
    try std.testing.expect(validate_route_pattern("/go/:slug") == null);
}

test "pattern: rejects empty" {
    try std.testing.expect(validate_route_pattern("") != null);
}

test "pattern: rejects no leading slash" {
    try std.testing.expect(validate_route_pattern("products") != null);
}

test "pattern: rejects trailing slash" {
    try std.testing.expect(validate_route_pattern("/products/") != null);
}

test "pattern: rejects double slash" {
    try std.testing.expect(validate_route_pattern("/products//list") != null);
}

test "pattern: rejects empty param name" {
    try std.testing.expect(validate_route_pattern("/products/:") != null);
}

test "pattern: rejects invalid param characters" {
    try std.testing.expect(validate_route_pattern("/products/:id-name") != null);
    try std.testing.expect(validate_route_pattern("/products/:id.format") != null);
}

test "pattern: accepts underscore in param" {
    try std.testing.expect(validate_route_pattern("/products/:product_id") == null);
}

test "match: PUT and PATCH" {
    const put = parse_match_directive("// match PUT /products/:id", "//");
    try std.testing.expect(put != null);
    try std.testing.expectEqual(put.?.method, .put);

    const patch = parse_match_directive("// match PATCH /products/:id", "//");
    try std.testing.expect(patch != null);
    try std.testing.expectEqual(patch.?.method, .patch);
}

// --- scan_file_content tests (match integration) ---

test "scan: route with match directive" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.translate, result.annotations.items[0].phase);
    try std.testing.expect(result.annotations.items[0].has_body);
    try std.testing.expect(result.annotations.items[0].route_match != null);
    try std.testing.expectEqual(result.annotations.items[0].route_match.?.method, .get);
    try std.testing.expect(std.mem.eql(u8, result.annotations.items[0].route_match.?.pattern, "/products/:id"));
}

test "scan: route without match directive" {
    var result = try test_scan(
        \\// [route] .get_product
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expect(result.annotations.items[0].route_match == null);
}

test "scan: match directive on non-route phase is error" {
    var result = try test_scan(
        \\// [handle] .get_product
        \\// match GET /products/:id
        \\pub fn handle() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
}

test "scan: match directive without annotation is error" {
    var result = try test_scan(
        \\// match GET /products/:id
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
}

test "scan: duplicate match directive is error" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
        \\// match POST /products
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
}

test "scan: invalid route pattern is error" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products//list
        \\pub fn route() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 1), result.errors);
    // Invalid pattern — annotation registered without route_match.
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expect(result.annotations.items[0].route_match == null);
}

test "scan: route with match followed by another annotation does not leak" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
        \\// [prefetch] .get_product
        \\pub fn prefetch() void {}
    );
    defer free_test_scan(&result.annotations);

    // Route had no body — error. Match pattern must be freed.
    try std.testing.expect(result.errors > 0);
}

test "scan: route with match at EOF does not leak" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// match GET /products/:id
    );
    defer free_test_scan(&result.annotations);

    // No function body follows — warning, no registration.
    // The duped pattern must be freed (std.testing.allocator catches leaks).
    try std.testing.expectEqual(@as(usize, 0), result.annotations.items.len);
}

// --- scan_file_content tests ---

fn test_scan(content: []const u8) !struct { annotations: std.ArrayList(Annotation), errors: u32 } {
    var annotations = std.ArrayList(Annotation).init(std.testing.allocator);
    const errors = try scan_file_content(std.testing.allocator, content, "//", "test.zig", &annotations);
    return .{ .annotations = annotations, .errors = errors };
}

fn free_test_scan(result: *std.ArrayList(Annotation)) void {
    for (result.items) |ann| {
        std.testing.allocator.free(ann.operation);
        std.testing.allocator.free(ann.file);
        if (ann.route_match) |rm| rm.deinit(std.testing.allocator);
    }
    result.deinit();
}

test "scan: annotation followed by code" {
    var result = try test_scan("// [route] .create_product\npub fn route() void {}\n");
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.translate, result.annotations.items[0].phase);
    try std.testing.expect(result.annotations.items[0].has_body);
}

test "scan: bodyless handle followed by next annotation" {
    var result = try test_scan(
        \\// [handle] .get_product
        \\// [render] .get_product
        \\pub fn render() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 2), result.annotations.items.len);
    // First: handle, bodyless.
    try std.testing.expectEqual(Phase.execute, result.annotations.items[0].phase);
    try std.testing.expect(!result.annotations.items[0].has_body);
    // Second: render, with body.
    try std.testing.expectEqual(Phase.render, result.annotations.items[1].phase);
    try std.testing.expect(result.annotations.items[1].has_body);
}

test "scan: bodyless handle at EOF" {
    var result = try test_scan("// [handle] .get_product\n");
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.execute, result.annotations.items[0].phase);
    try std.testing.expect(!result.annotations.items[0].has_body);
}

test "scan: non-handle without body followed by annotation is error" {
    var result = try test_scan(
        \\// [route] .get_product
        \\// [prefetch] .get_product
        \\pub fn prefetch() void {}
    );
    defer free_test_scan(&result.annotations);

    // Route without body is an error, prefetch with body succeeds.
    try std.testing.expectEqual(@as(u32, 1), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expectEqual(Phase.prefetch, result.annotations.items[0].phase);
}

test "scan: all 4 phases with bodyless handle" {
    var result = try test_scan(
        \\// [route] .get_product
        \\pub fn route() void {}
        \\
        \\// [prefetch] .get_product
        \\pub fn prefetch() void {}
        \\
        \\// [handle] .get_product
        \\
        \\// [render] .get_product
        \\pub fn render() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 4), result.annotations.items.len);
    try std.testing.expectEqual(Phase.translate, result.annotations.items[0].phase);
    try std.testing.expect(result.annotations.items[0].has_body);
    try std.testing.expectEqual(Phase.prefetch, result.annotations.items[1].phase);
    try std.testing.expect(result.annotations.items[1].has_body);
    try std.testing.expectEqual(Phase.execute, result.annotations.items[2].phase);
    try std.testing.expect(!result.annotations.items[2].has_body);
    try std.testing.expectEqual(Phase.render, result.annotations.items[3].phase);
    try std.testing.expect(result.annotations.items[3].has_body);
}

test "scan: handle with body is mutation" {
    var result = try test_scan(
        \\// [handle] .create_product
        \\pub fn handle() void {}
    );
    defer free_test_scan(&result.annotations);

    try std.testing.expectEqual(@as(u32, 0), result.errors);
    try std.testing.expectEqual(@as(usize, 1), result.annotations.items.len);
    try std.testing.expect(result.annotations.items[0].has_body);
}

// --- Status extraction tests ---

test "status: extracts HandleResult literal patterns" {
    const content =
        \\// [handle] .get_product
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = db;
        \\    if (ctx.prefetched.product == null)
        \\        return .{ .status = .not_found };
        \\    return .{};
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "status: deduplicates same status" {
    const content =
        \\// [handle] .get_product
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = db;
        \\    if (ctx.prefetched.product == null)
        \\        return .{ .status = .not_found };
        \\    if (!ctx.prefetched.product.?.active)
        \\        return .{ .status = .not_found };
        \\    return .{};
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
}

test "status: always includes ok" {
    const content =
        \\// [handle] .cancel_order
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = ctx; _ = db;
        \\    return .{ .status = .not_found };
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "status: multiple distinct statuses" {
    const content =
        \\// [handle] .create_order
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    if (missing) return .{ .status = .not_found };
        \\    if (low) return .{ .status = .insufficient_inventory };
        \\    db.execute(sql.products.update, .{ params });
        \\    return .{};
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 3), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
    try std.testing.expect(has_name(&ss, "insufficient_inventory"));
}

test "status: session_action variant still extracts ok" {
    const content =
        \\// [handle] .logout
        \\pub fn handle(ctx: Context, db: anytype) HandleResult {
        \\    _ = ctx; _ = db;
        \\    return .{ .session_action = .clear };
        \\}
    ;
    // .session_action = .clear doesn't match status patterns, but ok is always added.
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 1), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
}

test "status: TypeScript pattern" {
    const content =
        \\// [handle] .get_product
        \\export function handle(ctx) {
        \\    if (!ctx.prefetched.product)
        \\        return { status: "not_found", writes: [] };
        \\    return { status: "ok", writes: [] };
        \\}
    ;
    const ss = extract_statuses_from_handle(content, 1, ts_status_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "status: no body (no brace) still returns ok" {
    const content = "// [handle] .get_product\n";
    const ss = extract_statuses_from_handle(content, 1, zig_status_patterns);
    try std.testing.expectEqual(@as(u8, 1), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
}

test "status: StatusSet deduplication" {
    var ss = StatusSet{};
    ss.add("ok");
    ss.add("not_found");
    ss.add("ok"); // duplicate
    ss.add("not_found"); // duplicate
    try std.testing.expectEqual(@as(u8, 2), ss.len);
}

// --- Render extraction tests ---

test "render: extracts Zig switch arms" {
    const content =
        \\// [render] .get_product
        \\pub fn render(ctx: Context) []const u8 {
        \\    return switch (ctx.status) {
        \\        .ok => render_product(ctx),
        \\        .not_found => "<div>Not found</div>",
        \\    };
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, zig_adapter.render_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "render: extracts TS case statements" {
    const content =
        \\// [render] .get_product
        \\export function render(ctx) {
        \\    switch (ctx.status) {
        \\        case "ok": return renderProduct(ctx);
        \\        case "not_found": return "<div>Not found</div>";
        \\    }
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, ts_adapter.render_patterns);
    try std.testing.expectEqual(@as(u8, 2), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
}

test "render: suffix rejects non-switch-arm dots" {
    const content =
        \\// [render] .get_product
        \\pub fn render(ctx: Context) []const u8 {
        \\    const product = ctx.prefetched.product;
        \\    return switch (ctx.status) {
        \\        .ok => render_product(ctx),
        \\    };
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, zig_adapter.render_patterns);
    // .product and .prefetched should NOT be extracted — no "=>" suffix.
    // Only .ok should match.
    try std.testing.expectEqual(@as(u8, 1), ss.len);
    try std.testing.expect(has_name(&ss, "ok"));
}

// --- Integration test: scanner vs real handlers ---
//
// Reads every handler file from disk, extracts handle statuses using the
// scanner's patterns, and verifies they match the declared Status enum.
// Catches pattern regressions that unit tests with synthetic content miss.

test "integration: extracted handle statuses match declared Status enum" {
    const allocator = std.testing.allocator;

    // Read handler directory.
    var dir = try std.fs.cwd().openDir("handlers", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var checked: u32 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const content = try dir.readFileAlloc(allocator, entry.path, 1024 * 1024);
        defer allocator.free(content);

        // Find the [handle] annotation line.
        var handle_line: ?u32 = null;
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            if (parse_annotation(line, "//")) |ann| {
                if (ann.phase == .execute) handle_line = line_num;
            }
        }
        const start_line = handle_line orelse continue;

        // Extract statuses from handle body.
        const extracted = extract_statuses_from_handle(content, start_line, zig_adapter.handle_patterns);

        // Parse declared Status enum from "pub const Status = enum { ... };".
        var declared = StatusSet{};
        var decl_lines = std.mem.splitScalar(u8, content, '\n');
        while (decl_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "pub const Status = enum {")) {
                // Extract variants from "pub const Status = enum { ok, not_found };"
                const start = std.mem.indexOf(u8, trimmed, "{").? + 1;
                const end = std.mem.indexOf(u8, trimmed, "}").?;
                var variants = std.mem.splitScalar(u8, trimmed[start..end], ',');
                while (variants.next()) |v| {
                    const name = std.mem.trim(u8, v, " \t");
                    if (name.len > 0) declared.add(name);
                }
                break;
            }
        }

        // declared must have at least ok.
        assert(declared.len >= 1);
        assert(has_name(&declared, "ok"));

        // Every declared status must be in the extracted set.
        for (declared.slice()) |status| {
            if (!has_name(&extracted, status)) {
                std.debug.panic(
                    "handler {s}: declared status '{s}' not found by scanner extraction",
                    .{ entry.basename, status },
                );
            }
        }

        // Every extracted status must be in the declared set.
        for (extracted.slice()) |status| {
            if (!has_name(&declared, status)) {
                std.debug.panic(
                    "handler {s}: scanner extracted '{s}' but it's not in declared Status enum",
                    .{ entry.basename, status },
                );
            }
        }

        // route_method/route_pattern constants removed — annotations are the
        // single source of truth. Cross-validation no longer needed.

        checked += 1;
    }

    // Must have checked all 24 handlers.
    try std.testing.expectEqual(@as(u32, 24), checked);
}

test "render: Zig multi-status with other switches" {
    const content =
        \\// [render] .complete_order
        \\pub fn render(ctx: Context, db: anytype) []const u8 {
        \\    switch (ctx.status) {
        \\        .not_found => return "<div>Not found</div>",
        \\        .ok => {},
        \\    }
        \\    pos += h.raw(buf[pos..], switch (order.status) {
        \\        .pending => "Pending",
        \\        .confirmed => "Confirmed",
        \\        .failed => "Failed",
        \\        .cancelled => "Cancelled",
        \\    });
        \\    return buf[0..pos];
        \\}
    ;
    const ss = extract_statuses_from_body(content, 1, zig_adapter.render_patterns);
    // Picks up all switch arms: ok, not_found, pending, confirmed, failed, cancelled.
    // The exhaustiveness check only looks for handle statuses in this set,
    // so extra statuses from other switches are harmless.
    try std.testing.expect(has_name(&ss, "ok"));
    try std.testing.expect(has_name(&ss, "not_found"));
    try std.testing.expect(has_name(&ss, "pending"));
}

// =====================================================================
// SQL validation tests
// =====================================================================

test "sql: SqlStringIterator extracts SQL from TS prefetch" {
    const content =
        \\export function prefetch(msg) {
        \\  return {
        \\    product: { sql: "SELECT id, name FROM products WHERE id = ?1", params: [msg.id], mode: "one" },
        \\  };
        \\}
    ;
    var iter = SqlStringIterator.init(content, 1, '"');
    const sql1 = iter.next();
    try std.testing.expect(sql1 != null);
    try std.testing.expect(sql_starts_with_select(sql1.?));
    try std.testing.expect(iter.next() == null); // "one" is not SQL
}

test "sql: SqlStringIterator extracts SQL from TS handle" {
    const content =
        \\export function handle(ctx, db) {
        \\  db.execute("INSERT INTO products VALUES (?1, ?2)", [ctx.id, ctx.name]);
        \\  return "ok";
        \\}
    ;
    var iter = SqlStringIterator.init(content, 1, '"');
    const sql1 = iter.next();
    try std.testing.expect(sql1 != null);
    try std.testing.expect(sql_starts_with_write(sql1.?));
    try std.testing.expect(iter.next() == null); // "ok" is not SQL
}

test "sql: SqlStringIterator skips non-SQL strings" {
    const content =
        \\export function render(ctx) {
        \\  if (ctx.status === "ok") return "<div>Done</div>";
        \\  return "<div>Error</div>";
        \\}
    ;
    var iter = SqlStringIterator.init(content, 1, '"');
    // "ok", "<div>Done</div>", "<div>Error</div>" — none are SQL.
    try std.testing.expect(iter.next() == null);
}

test "sql: SqlStringIterator scoped to function body" {
    // Two functions — SQL in the second must not be found when scanning the first.
    const content =
        \\export function prefetch(msg) {
        \\  return { x: { sql: "SELECT 1", params: [], mode: "one" } };
        \\}
        \\export function handle(ctx, db) {
        \\  db.execute("INSERT INTO t VALUES (?1)", [1]);
        \\  return "ok";
        \\}
    ;
    // Scan from line 1 (prefetch) — should only find SELECT.
    var iter1 = SqlStringIterator.init(content, 1, '"');
    const sql1 = iter1.next();
    try std.testing.expect(sql1 != null);
    try std.testing.expect(sql_starts_with_select(sql1.?));
    try std.testing.expect(iter1.next() == null); // INSERT is in the next function

    // Scan from line 4 (handle) — should only find INSERT.
    var iter2 = SqlStringIterator.init(content, 4, '"');
    const sql2 = iter2.next();
    try std.testing.expect(sql2 != null);
    try std.testing.expect(sql_starts_with_write(sql2.?));
    try std.testing.expect(iter2.next() == null);
}

test "sql: sql_starts_with_select case insensitive" {
    try std.testing.expect(sql_starts_with_select("SELECT id FROM t"));
    try std.testing.expect(sql_starts_with_select("select id FROM t"));
    try std.testing.expect(sql_starts_with_select("  SELECT id FROM t"));
    try std.testing.expect(!sql_starts_with_select("INSERT INTO t VALUES (1)"));
    try std.testing.expect(!sql_starts_with_select("DELETE FROM t"));
    try std.testing.expect(!sql_starts_with_select(""));
}

test "sql: sql_starts_with_write" {
    try std.testing.expect(sql_starts_with_write("INSERT INTO t VALUES (1)"));
    try std.testing.expect(sql_starts_with_write("UPDATE t SET x = 1"));
    try std.testing.expect(sql_starts_with_write("DELETE FROM t WHERE id = 1"));
    try std.testing.expect(sql_starts_with_write("  insert into t values (1)"));
    try std.testing.expect(!sql_starts_with_write("SELECT id FROM t"));
    try std.testing.expect(!sql_starts_with_write(""));
}

test "sql: body_references_sql detects execute calls" {
    try std.testing.expect(body_references_sql("db.execute(sql, params)", .execute));
    try std.testing.expect(!body_references_sql("self.execute(callback)", .execute)); // not db.execute
    try std.testing.expect(!body_references_sql("return \"ok\"", .execute));
    try std.testing.expect(body_references_sql("{ sql: variable }", .prefetch));
    try std.testing.expect(!body_references_sql("return {}", .prefetch));
}

test "sql: braces inside strings don't break body scoping" {
    const content =
        \\export function prefetch(msg) {
        \\  return { x: { sql: "SELECT json_col FROM t WHERE data = '{}'", params: [], mode: "one" } };
        \\}
        \\export function handle(ctx, db) {
        \\  db.execute("INSERT INTO t VALUES (?1)", [1]);
        \\  return "ok";
        \\}
    ;
    // Prefetch body should contain the SELECT but not the INSERT.
    var iter = SqlStringIterator.init(content, 1, '"');
    const sql1 = iter.next();
    try std.testing.expect(sql1 != null);
    try std.testing.expect(sql_starts_with_select(sql1.?));
    try std.testing.expect(iter.next() == null); // INSERT is in handle, not prefetch
}

test "sql: Zig handle with comptime SQL constant" {
    // Zig handlers use db.execute(t.sql.products.insert, ...) — no string literal.
    const content =
        \\pub fn handle(ctx: Context, db: anytype) t.HandleResult {
        \\    db.execute(t.sql.products.insert, .{ entity.id, entity.name });
        \\    return .{};
        \\}
    ;
    var iter = SqlStringIterator.init(content, 1, '"');
    // No SQL string literals found.
    try std.testing.expect(iter.next() == null);
    // But body references execute.
    const body = SqlStringIterator.init(content, 1, '"').body;
    try std.testing.expect(body_references_sql(body, .execute));
}
