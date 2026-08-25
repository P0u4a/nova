//! The `find` and `grep` tools, both backed by the fff index (`search.zig`).
//!
//! Two tools, one file, because they share their argument plumbing and their
//! result shaping — and because they are the same decision for the model: search
//! by path, or search by content.
//!
//! When the index is unavailable (library not built, or still scanning) the layer
//! underneath falls back to `rg`/`grep`/`find` through a shell and says so in the
//! result. Callers get an answer either way; only ranking and pagination differ.

const std = @import("std");

const common = @import("common.zig");
const search = @import("../search.zig");

const assert = std.debug.assert;

/// Result cap when the model doesn't pick one. High enough to answer "where is
/// this used" in a single call, low enough not to bury the reply.
const limit_default: u32 = 50;
const limit_max: u32 = 500;
const context_max: u32 = 20;

pub const find_tool: common.Tool = .{
    .name = "find",
    .description = @embedFile("../prompts/tools/find.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "query",
                .kind = .string,
                .description = "Path fragment to match, e.g. `session writer` or `tools/edit`. Matched fuzzily against every indexed path, best first — not a glob.",
                .required = true,
            },
            .{
                .name = "limit",
                .kind = .integer,
                .description = "Maximum results (default 50, max 500).",
                .required = false,
            },
            .{
                .name = "cursor",
                .kind = .string,
                .description = "Continuation token from a previous truncated result, to fetch the next page.",
                .required = false,
            },
        },
    },
    .run = runFind,
};

pub const grep_tool: common.Tool = .{
    .name = "grep",
    .description = @embedFile("../prompts/tools/grep.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "patterns",
                .kind = .string_array,
                .description = "One or more strings to search for. Multiple patterns are searched in a single pass and any line matching any of them is reported — much cheaper than one call per pattern.",
                .required = true,
            },
            .{
                .name = "glob",
                .kind = .string,
                .description = "Restrict to matching files, e.g. `*.zig` or `/src/`.",
                .required = false,
            },
            .{
                .name = "regex",
                .kind = .boolean,
                .description = "Treat the pattern as a regular expression instead of literal text. Only valid with a single pattern.",
                .required = false,
            },
            .{
                .name = "context",
                .kind = .integer,
                .description = "Lines of surrounding context to include either side of each match (default 0, max 20).",
                .required = false,
            },
            .{
                .name = "limit",
                .kind = .integer,
                .description = "Maximum matches (default 50, max 500).",
                .required = false,
            },
            .{
                .name = "cursor",
                .kind = .string,
                .description = "Continuation token from a previous truncated result, to fetch the next page.",
                .required = false,
            },
        },
    },
    .run = runGrep,
};

const FindArgs = struct {
    query: ?[]const u8 = null,
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
};

const GrepArgs = struct {
    patterns: ?[][]const u8 = null,
    /// Accepted so a single-pattern call can use the singular spelling.
    pattern: ?[]const u8 = null,
    glob: ?[]const u8 = null,
    regex: ?bool = null,
    context: ?u32 = null,
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
};

fn runFind(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(FindArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch {
        return common.failFmt(gpa, 2, "find: could not parse arguments as JSON.\n", .{});
    };
    defer parsed.deinit();

    const query = parsed.value.query orelse "";
    if (query.len == 0) return common.failFmt(gpa, 2, "find: `query` is required.\n", .{});

    var result = search.run(gpa, io, cwd, .{
        .op = .find,
        .query = query,
        .limit = clampLimit(parsed.value.limit),
        .cursor = parsed.value.cursor,
    }) catch |err| return searchError(gpa, "find", err);
    defer result.deinit(gpa);
    return intoOutput(gpa, &result);
}

fn runGrep(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(GrepArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch {
        return common.failFmt(gpa, 2, "grep: could not parse arguments as JSON.\n", .{});
    };
    defer parsed.deinit();

    const count = patternCount(parsed.value);
    if (count == 0) return common.failFmt(gpa, 2, "grep: `patterns` must contain at least one non-empty string.\n", .{});
    const regex = parsed.value.regex orelse false;
    if (regex and count > 1) {
        return common.failFmt(gpa, 2, "grep: `regex` works with a single pattern. Either drop it (literal multi-pattern search) or combine the patterns into one alternation.\n", .{});
    }

    // fff's multi-pattern entry point takes needles joined by newline, which is
    // also what the pagination cursor hashes, so build that once here.
    const joined = try joinPatterns(gpa, parsed.value);
    defer gpa.free(joined);

    // A regex search has no separate constraint parameter — fff reads the file
    // filter from the front of the query itself (`*.zig pattern`).
    const query = if (regex and parsed.value.glob != null)
        try std.fmt.allocPrint(gpa, "{s} {s}", .{ parsed.value.glob.?, joined })
    else
        try gpa.dupe(u8, joined);
    defer gpa.free(query);

    var result = search.run(gpa, io, cwd, .{
        .op = .grep,
        .query = query,
        .glob = if (regex) null else parsed.value.glob,
        .regex = regex,
        .context = @min(parsed.value.context orelse 0, context_max),
        .limit = clampLimit(parsed.value.limit),
        .cursor = parsed.value.cursor,
    }) catch |err| return searchError(gpa, "grep", err);
    defer result.deinit(gpa);
    return intoOutput(gpa, &result);
}

fn patternCount(args: GrepArgs) usize {
    var count: usize = 0;
    if (args.patterns) |list| {
        for (list) |pattern| {
            if (pattern.len > 0) count += 1;
        }
    }
    if (args.pattern) |pattern| {
        if (pattern.len > 0) count += 1;
    }
    return count;
}

fn joinPatterns(gpa: std.mem.Allocator, args: GrepArgs) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (args.patterns) |list| {
        for (list) |pattern| {
            if (pattern.len == 0) continue;
            if (out.items.len > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, pattern);
        }
    }
    if (args.pattern) |pattern| {
        if (pattern.len > 0) {
            if (out.items.len > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, pattern);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn clampLimit(requested: ?u32) u32 {
    const limit = requested orelse limit_default;
    if (limit == 0) return limit_default;
    return @min(limit, limit_max);
}

/// Move a `search.Result` into a tool `Output`. The search layer already reports
/// its own failures as non-zero exit with text on stderr, so this only has to
/// transfer ownership.
fn intoOutput(gpa: std.mem.Allocator, result: *search.Result) common.Error!common.Output {
    const stdout = result.stdout;
    const stderr = result.stderr;
    const code = result.code;
    result.* = .{ .stdout = &.{}, .stderr = &.{}, .code = 0 };
    _ = gpa;
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

fn searchError(gpa: std.mem.Allocator, name: []const u8, err: anyerror) common.Error!common.Output {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.InvalidCursor => common.failFmt(gpa, 2, "{s}: that cursor does not match this search. Drop `cursor` and start again.\n", .{name}),
        else => common.failFmt(gpa, 2, "{s}: search failed ({s}).\n", .{ name, @errorName(err) }),
    };
}

test "grep rejects regex with more than one pattern" {
    const gpa = std.testing.allocator;
    var output = try runGrep(gpa, std.testing.io, ".",
        \\{"patterns":["a","b"],"regex":true}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "single pattern") != null);
}

test "grep rejects an empty pattern list" {
    const gpa = std.testing.allocator;
    var output = try runGrep(gpa, std.testing.io, ".",
        \\{"patterns":[]}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "at least one") != null);
}

test "find requires a query" {
    const gpa = std.testing.allocator;
    var output = try runFind(gpa, std.testing.io, ".",
        \\{}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "`query` is required") != null);
}

test "patterns join with newlines, singular and plural forms together" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(GrepArgs, gpa,
        \\{"patterns":["alpha","beta"],"pattern":"gamma"}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const joined = try joinPatterns(gpa, parsed.value);
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma", joined);
    try std.testing.expectEqual(@as(usize, 3), patternCount(parsed.value));
}

test "empty patterns are skipped rather than searched for" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(GrepArgs, gpa,
        \\{"patterns":["","real",""]}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), patternCount(parsed.value));
    const joined = try joinPatterns(gpa, parsed.value);
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("real", joined);
}

test "limit is clamped to a sane range" {
    try std.testing.expectEqual(limit_default, clampLimit(null));
    try std.testing.expectEqual(limit_default, clampLimit(0));
    try std.testing.expectEqual(@as(u32, 10), clampLimit(10));
    try std.testing.expectEqual(limit_max, clampLimit(100_000));
}
