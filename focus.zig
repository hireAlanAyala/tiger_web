//! Focus CLI — single Zig binary for project scaffolding, build, and dev.
//!
//! Replaces the shell scripts (focus, focus-internal). All tooling
//! centralized in Zig per TB's principle: "Bash is not cross platform,
//! suffers from high accidental complexity, and is a second language."
//!
//! Subcommands:
//!   new --ts <name>    Scaffold a TypeScript project
//!   build <path>       Scan annotations + generate dispatch
//!   dev <path>         Build + server + sidecar + watch + reload
//!   schema <args>      Apply/reset database schema
//!   docs               Print framework reference

const std = @import("std");
const stdx = @import("stdx");
const scanner = @import("annotation_scanner.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const CLIArgs = union(enum) {
    new: NewArgs,
    build: BuildArgs,
    // dev: DevArgs,     // TODO: implement
    // schema: SchemaArgs, // exists in main.zig, expose here
    // docs: void,       // TODO: @embedFile reference

    pub const help =
        \\Usage:
        \\  focus new --ts <name>    Scaffold a TypeScript project
        \\  focus build <path>       Scan annotations + generate dispatch
        \\  focus dev <path>         Build + server + sidecar + watch + reload
        \\  focus schema <args>      Apply/reset database schema
        \\  focus docs               Print framework reference
        \\
    ;
};

const NewArgs = struct {
    ts: bool = false,
    // go: bool = false,  // future
    // py: bool = false,  // future
    /// Positional: project name
    @"--": void,
    name: []const u8,
};

const BuildArgs = struct {
    /// Positional: handler source path
    @"--": void,
    path: []const u8,
};

pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa_allocator.deinit()) {
        .ok => {},
        .leak => @panic("memory leak"),
    };
    const gpa = gpa_allocator.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    const cli = stdx.flags(&args, CLIArgs);

    switch (cli) {
        .new => |new_args| try cmd_new(new_args),
        .build => |build_args| try cmd_build(gpa, build_args),
    }
}

// =============================================================
// focus new
// =============================================================

fn cmd_new(args: NewArgs) !void {
    if (!args.ts) {
        std.io.getStdErr().writer().print("error: specify a language: --ts\n", .{}) catch {};
        std.process.exit(1);
    }

    const name = args.name;
    const stdout = std.io.getStdOut().writer();

    // Create project directory.
    std.fs.cwd().makeDir(name) catch |err| {
        if (err == error.PathAlreadyExists) {
            stdout.print("error: '{s}' already exists.\n", .{name}) catch {};
            std.process.exit(1);
        }
        return err;
    };

    // Write template files.
    const templates = .{
        .{ "schema.sql", @embedFile("templates/ts/schema.sql") },
        .{ ".focus", @embedFile("templates/ts/dot-focus") },
        .{ ".gitignore", @embedFile("templates/ts/dot-gitignore") },
        .{ "package.json", @embedFile("templates/ts/package.json") },
        .{ "tsconfig.json", @embedFile("templates/ts/tsconfig.json") },
        .{ "src/list_items.ts", @embedFile("templates/ts/src/list_items.ts") },
        .{ "src/create_item.ts", @embedFile("templates/ts/src/create_item.ts") },
        .{ "focus/sidecar.ts", @embedFile("templates/ts/focus/sidecar.ts") },
        .{ "focus/codegen.ts", @embedFile("templates/ts/focus/codegen.ts") },
        .{ "focus/types.ts", @embedFile("templates/ts/focus/types.ts") },
        .{ "focus/serde.ts", @embedFile("templates/ts/focus/serde.ts") },
        .{ "focus/routing.ts", @embedFile("templates/ts/focus/routing.ts") },
        .{ "focus/shm.c", @embedFile("templates/ts/focus/shm.c") },
    };

    const dir = try std.fs.cwd().openDir(name, .{});
    dir.makeDir("src") catch {};
    dir.makeDir("focus") catch {};

    inline for (templates) |t| {
        const path = t[0];
        const content = t[1];
        if (std.mem.indexOfScalar(u8, path, '/')) |_| {
            // Has subdirectory — already created above.
        }
        const file = try dir.createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }


    try stdout.print(
        \\
        \\  Created {s}/
        \\
        \\  Next steps:
        \\    cd {s}
        \\    focus dev src/
        \\
        \\
    , .{ name, name });
}

// =============================================================
// focus build
// =============================================================

fn cmd_build(gpa: std.mem.Allocator, args: BuildArgs) !void {
    const path = args.path;
    const stdout = std.io.getStdOut().writer();

    // Arena for scanner (allocates freely, freed after scan completes).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Read .focus file for build hook.
    const dot_focus = std.fs.cwd().readFileAlloc(allocator, ".focus", 4096) catch {
        try stdout.print("error: no .focus file — run 'focus new' or create one with:\n  build = <your build command>\n  start = <your sidecar command>\n", .{});
        std.process.exit(1);
    };
    const build_hook = parse_hook(dot_focus, "build") orelse {
        try stdout.print("error: .focus file missing 'build' hook\n", .{});
        std.process.exit(1);
    };

    // Ensure focus/ directory exists for generated output.
    std.fs.cwd().makeDir("focus") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Step 1: Run the annotation scanner (linked in-process — no subprocess).
    try scanner.scan(allocator, .{
        .scan_dir = path,
        .manifest_path = "focus/manifest.json",
        .registry_path = "focus/operations.json",
        .operations_zig_path = "focus/operations.generated.zig",
        .routes_zig_path = "focus/routes.generated.zig",
    });

    // Step 2: Run the user's build hook (from .focus file).
    try run_cmd(allocator, &.{ "sh", "-c", build_hook });

    try stdout.print("Build complete.\n", .{});
}

/// Parse a hook value from .focus file content. Format: "key = rest of line"
fn parse_hook(content: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, key)) {
            const rest = line[key.len..];
            if (rest.len > 0 and rest[0] == ' ') {
                // "key = value" → skip " = "
                if (rest.len > 2 and rest[1] == '=' and rest[2] == ' ') {
                    return rest[3..];
                }
            }
            if (rest.len > 0 and rest[0] == '=') {
                // "key=value" → skip "="
                return rest[1..];
            }
        }
    }
    return null;
}

/// Run a command, wait for exit. Errors exit the process.
fn run_cmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    if (term.Exited != 0) {
        std.io.getStdErr().writer().print("command failed (exit {d})\n", .{term.Exited}) catch {};
        std.process.exit(1);
    }
}
