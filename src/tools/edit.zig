//! The `edit` tool: exact-text replacement in one file.
//!
//! File I/O and the tool contract only — the text rules live in `edit_text.zig`.
//! A rejected edit leaves the file byte-identical, and every rejection explains
//! what to change rather than just failing.

const std = @import("std");

const common = @import("common.zig");
const edit_text = @import("edit_text.zig");

const assert = std.debug.assert;

/// Cap on the file size this tool will rewrite. Well past any source file; the
/// point is to fail cleanly on a multi-gigabyte blob rather than try to buffer it
/// twice.
const file_bytes_max: usize = 16 * 1024 * 1024;

/// Context lines each side of a change in the displayed diff.
const diff_context: usize = 4;

pub const tool: common.Tool = .{
    .name = "edit",
    .description = @embedFile("../prompts/tools/edit.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "path",
                .kind = .string,
                .description = "File to edit. Relative to the project unless absolute.",
                .required = true,
            },
            .{
                .name = "edits",
                .kind = .{ .object_array = &.{
                    .{
                        .name = "old_text",
                        .kind = .string,
                        .description = "Exact text to replace. Must appear exactly once in the file and must not overlap another edit's old_text.",
                        .required = true,
                    },
                    .{
                        .name = "new_text",
                        .kind = .string,
                        .description = "Text to put in its place. May be empty to delete.",
                        .required = true,
                    },
                } },
                .description = "One or more replacements. Each is matched against the original file, not against the result of the others, so they never need to account for each other. Do not include overlapping or nested edits — merge those into one.",
                .required = true,
            },
        },
    },
    .run = run,
    .display = display,
};

const JsonEdit = struct {
    old_text: ?[]const u8 = null,
    new_text: ?[]const u8 = null,
    /// Accepted as an alias so a model that has learned the camelCase spelling
    /// from other harnesses is not silently rejected.
    oldText: ?[]const u8 = null,
    newText: ?[]const u8 = null,

    fn old(self: JsonEdit) ?[]const u8 {
        return self.old_text orelse self.oldText;
    }

    fn new(self: JsonEdit) ?[]const u8 {
        return self.new_text orelse self.newText;
    }
};

const JsonArgs = struct {
    path: ?[]const u8 = null,
    edits: ?[]JsonEdit = null,
    /// Single-replacement shorthand, hoisted into `edits` when present.
    old_text: ?[]const u8 = null,
    new_text: ?[]const u8 = null,
    oldText: ?[]const u8 = null,
    newText: ?[]const u8 = null,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch {
        return common.failFmt(gpa, 2, "edit: could not parse arguments as JSON.\n", .{});
    };
    defer parsed.deinit();

    const path = parsed.value.path orelse {
        return common.failFmt(gpa, 2, "edit: `path` is required.\n", .{});
    };
    if (path.len == 0) return common.failFmt(gpa, 2, "edit: `path` is required.\n", .{});

    var edits: std.ArrayList(edit_text.Edit) = .empty;
    defer edits.deinit(gpa);
    try collectEdits(gpa, parsed.value, &edits);
    if (edits.items.len == 0) {
        return common.failFmt(gpa, 2, "edit {s}: provide `edits` (or a single `old_text`/`new_text` pair).\n", .{path});
    }

    const absolute = common.joinPath(gpa, cwd, path) catch return error.OutOfMemory;
    defer gpa.free(absolute);

    const original = common.readFileBytes(gpa, io, absolute, file_bytes_max) catch |err| {
        return common.failFmt(gpa, 2, "edit {s}: {s}\n", .{ path, readErrorText(err) });
    };
    defer gpa.free(original);

    // Preserve the two things a naive rewrite loses: a leading BOM and the file's
    // dominant line ending. Matching happens on the LF-normalized body.
    const had_bom = std.mem.startsWith(u8, original, edit_text.bom);
    const body = edit_text.stripBom(original);
    const ending = edit_text.detectLineEnding(body);
    const normalized = try edit_text.normalizeToLf(gpa, body);
    defer gpa.free(normalized);

    var failure: edit_text.Failure = undefined;
    var applied = edit_text.applyEdits(gpa, normalized, edits.items, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const message = edit_text.describe(gpa, path, edits.items.len, failure) catch return error.OutOfMemory;
            defer gpa.free(message);
            return common.failFmt(gpa, 2, "{s}\n", .{message});
        },
    };
    defer applied.deinit(gpa);

    const restored = try edit_text.restoreLineEndings(gpa, applied.updated, ending);
    defer gpa.free(restored);
    try writeFile(gpa, io, absolute, restored, had_bom);

    const counts = edit_text.countChanges(applied.base, applied.updated);
    const observation = try std.fmt.allocPrint(
        gpa,
        "Edited {s}: {d} replacement(s), +{d} -{d} lines.{s}",
        .{
            path,
            edits.items.len,
            counts.added,
            counts.removed,
            if (applied.used_fuzzy)
                " (matched after normalizing whitespace and Unicode punctuation — copy text verbatim next time)"
            else
                "",
        },
    );
    errdefer gpa.free(observation);
    const diff = try edit_text.renderDiff(gpa, path, applied.base, applied.updated, diff_context);
    errdefer gpa.free(diff);

    const stderr = try gpa.alloc(u8, 0);
    return .{
        .stdout = observation,
        .stderr = stderr,
        .code = 0,
        .display = diff,
        .display_kind = .diff,
    };
}

/// Flatten the accepted argument shapes into one edit list: an `edits` array, a
/// top-level `old_text`/`new_text` pair, or both.
fn collectEdits(
    gpa: std.mem.Allocator,
    args: JsonArgs,
    out: *std.ArrayList(edit_text.Edit),
) !void {
    if (args.edits) |list| {
        for (list) |entry| {
            try out.append(gpa, .{
                .old_text = entry.old() orelse "",
                .new_text = entry.new() orelse "",
            });
        }
    }
    const single_old = args.old_text orelse args.oldText;
    const single_new = args.new_text orelse args.newText;
    if (single_old != null or single_new != null) {
        try out.append(gpa, .{
            .old_text = single_old orelse "",
            .new_text = single_new orelse "",
        });
    }
}

fn writeFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    absolute: []const u8,
    content: []const u8,
    with_bom: bool,
) common.Error!void {
    _ = gpa;
    var file = std.Io.Dir.createFile(.cwd(), io, absolute, .{ .truncate = true }) catch return error.Unexpected;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    if (with_bom) writer.interface.writeAll(edit_text.bom) catch return error.Unexpected;
    writer.interface.writeAll(content) catch return error.Unexpected;
    writer.interface.flush() catch return error.Unexpected;
}

fn readErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file. Create it with `write` instead.",
        error.IsDir => "that path is a directory, not a file.",
        error.AccessDenied => "permission denied.",
        error.StreamTooLong => "file is too large to edit.",
        else => "could not read the file.",
    };
}

pub fn display(gpa: std.mem.Allocator, arguments: []const u8) std.mem.Allocator.Error!common.ToolDisplay {
    const path = try common.extractStringField(gpa, arguments, "path", "edit");
    errdefer gpa.free(path);
    const label = try std.fmt.allocPrint(gpa, "Edit {s}", .{path});
    gpa.free(path);
    return .{ .label = label };
}

// === tests ==================================================================

/// Run the tool against a scratch file and return its `Output`.
fn runInTemp(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    initial: ?[]const u8,
    arguments: []const u8,
) !common.Output {
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const dir_rel = ".zig-cache/edit-tool-test";
    try std.Io.Dir.createDirPath(.cwd(), io, dir_rel);
    const rel = try std.fs.path.join(gpa, &.{ dir_rel, name });
    defer gpa.free(rel);
    if (initial) |content| {
        var file = try std.Io.Dir.createFile(.cwd(), io, rel, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    } else {
        std.Io.Dir.cwd().deleteFile(io, rel) catch {};
    }
    const cwd = try std.fs.path.join(gpa, &.{ root, dir_rel });
    defer gpa.free(cwd);
    return run(gpa, io, cwd, arguments);
}

fn readTemp(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const rel = try std.fs.path.join(gpa, &.{ ".zig-cache/edit-tool-test", name });
    defer gpa.free(rel);
    var file = try std.Io.Dir.cwd().openFile(io, rel, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(file_bytes_max));
}

test "edit replaces text and reports a diff" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io, "a.txt", "alpha\nbeta\n",
        \\{"path":"a.txt","edits":[{"old_text":"beta","new_text":"gamma"}]}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqual(common.DisplayKind.diff, output.display_kind);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "1 replacement(s)") != null);

    const content = try readTemp(gpa, io, "a.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("alpha\ngamma\n", content);
}

test "edit accepts the camelCase spelling and the single-pair shorthand" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io, "b.txt", "one\n",
        \\{"path":"b.txt","oldText":"one","newText":"two"}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    const content = try readTemp(gpa, io, "b.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("two\n", content);
}

test "edit preserves CRLF line endings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io, "crlf.txt", "one\r\ntwo\r\n",
        \\{"path":"crlf.txt","edits":[{"old_text":"two","new_text":"TWO"}]}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    const content = try readTemp(gpa, io, "crlf.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("one\r\nTWO\r\n", content);
}

test "edit leaves the file untouched when a replacement is ambiguous" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io, "dup.txt", "x\nx\n",
        \\{"path":"dup.txt","edits":[{"old_text":"x","new_text":"y"}]}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "matches 2 places") != null);

    const content = try readTemp(gpa, io, "dup.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("x\nx\n", content);
}

test "edit on a missing file points at write" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io, "absent.txt", null,
        \\{"path":"absent.txt","edits":[{"old_text":"a","new_text":"b"}]}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "write") != null);
}

test "edit display names the file" {
    const gpa = std.testing.allocator;
    var shown = try display(gpa, "{\"path\":\"src/main.zig\"}");
    defer shown.deinit(gpa);
    try std.testing.expectEqualStrings("Edit src/main.zig", shown.label);
}
