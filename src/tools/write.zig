//! The `write` tool: create a file, or replace one wholesale.
//!
//! Deliberately blunt — no matching, no merging. Parent directories are created,
//! and an existing file is overwritten. `edit` is the tool for touching part of a
//! file; this one is for new files and full rewrites.

const std = @import("std");

const common = @import("common.zig");
const workspace_path = @import("workspace_path.zig");
const edit_text = @import("edit_text.zig");

const file_bytes_max: usize = 16 * 1024 * 1024;
const diff_context: usize = 4;

pub const tool: common.Tool = .{
    .name = "write",
    .description = @embedFile("../prompts/tools/write.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "path",
                .kind = .string,
                .description = "File to write. Relative to the project unless absolute; must stay inside the project. Parent directories are created.",
                .required = true,
            },
            .{
                .name = "content",
                .kind = .string,
                .description = "Full contents to write. Replaces the file entirely when it already exists.",
                .required = true,
            },
        },
    },
    .run = run,
};

const JsonArgs = struct {
    path: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch {
        return common.failFmt(gpa, 2, "write: could not parse arguments as JSON.\n", .{});
    };
    defer parsed.deinit();

    const path = parsed.value.path orelse {
        return common.failFmt(gpa, 2, "write: `path` is required.\n", .{});
    };
    if (path.len == 0) return common.failFmt(gpa, 2, "write: `path` is required.\n", .{});
    const content = parsed.value.content orelse {
        return common.failFmt(gpa, 2, "write {s}: `content` is required (pass \"\" to truncate).\n", .{path});
    };

    // `write` creates missing parents, so `resolve` does it component by component
    // — each one re-opened without following symlinks, so a racing link is still
    // caught instead of being created through.
    var resolved = workspace_path.resolve(gpa, io, cwd, path, .{ .create_parents = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        var buffer: [512]u8 = undefined;
        return common.failFmt(gpa, 2, "{s}\n", .{workspace_path.describe(err, "write", path, &buffer)});
    };
    defer resolved.deinit(gpa, io);

    // Read any existing file first, so the result can show what changed rather
    // than just asserting a write happened. Absent file: treated as empty.
    const previous: ?[]u8 = readVerified(gpa, io, &resolved) catch null;
    defer if (previous) |old| gpa.free(old);

    writeAll(io, &resolved, content) catch {
        return common.failFmt(gpa, 2, "write {s}: could not write the file.\n", .{path});
    };

    const observation = try std.fmt.allocPrint(
        gpa,
        "Wrote {s} ({d} bytes, {d} lines){s}.",
        .{ path, content.len, lineCount(content), if (previous == null) "" else " — replaced existing file" },
    );
    errdefer gpa.free(observation);

    const before = edit_text.stripBom(previous orelse "");
    const before_lf = try edit_text.normalizeToLf(gpa, before);
    defer gpa.free(before_lf);
    const after_lf = try edit_text.normalizeToLf(gpa, content);
    defer gpa.free(after_lf);
    const diff = try edit_text.renderDiff(gpa, path, before_lf, after_lf, diff_context);
    defer gpa.free(diff);

    var details: std.Io.Writer.Allocating = .init(gpa);
    errdefer details.deinit();
    details.writer.writeAll("{\"diff\":") catch return error.OutOfMemory;
    std.json.Stringify.value(diff, .{}, &details.writer) catch return error.OutOfMemory;
    details.writer.writeByte('}') catch return error.OutOfMemory;

    const stderr = try gpa.alloc(u8, 0);
    return .{
        .stdout = observation,
        .stderr = stderr,
        .code = 0,
        .details_json = details.toOwnedSlice() catch return error.OutOfMemory,
    };
}

fn writeAll(io: std.Io, resolved: *const workspace_path.Resolved, content: []const u8) !void {
    var file = try resolved.createFile(io);
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

/// Read the existing file, if any, through the verified parent handle rather than
/// by absolute path — so a symlink planted at the target is not read through.
fn readVerified(gpa: std.mem.Allocator, io: std.Io, resolved: *const workspace_path.Resolved) ![]u8 {
    var file = try resolved.openFile(io);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(file_bytes_max));
}

fn lineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    var count: usize = 0;
    for (content) |byte| {
        if (byte == '\n') count += 1;
    }
    // A file not ending in a newline still has a final line.
    if (content[content.len - 1] != '\n') count += 1;
    return count;
}

const test_dir = ".zig-cache/write-tool-test";

fn runInTemp(gpa: std.mem.Allocator, io: std.Io, arguments: []const u8) !common.Output {
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, test_dir);
    const cwd = try std.fs.path.join(gpa, &.{ root, test_dir });
    defer gpa.free(cwd);
    return run(gpa, io, cwd, arguments);
}

fn readTemp(gpa: std.mem.Allocator, io: std.Io, rel_name: []const u8) ![]u8 {
    const rel = try std.fs.path.join(gpa, &.{ test_dir, rel_name });
    defer gpa.free(rel);
    var file = try std.Io.Dir.cwd().openFile(io, rel, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(file_bytes_max));
}

test "write creates a file and reports its size" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io,
        \\{"path":"new.txt","content":"hello\nworld\n"}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "12 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "2 lines") != null);

    const content = try readTemp(gpa, io, "new.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hello\nworld\n", content);
}

test "write creates missing parent directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io,
        \\{"path":"nested/deeper/file.txt","content":"x\n"}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    const content = try readTemp(gpa, io, "nested/deeper/file.txt");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("x\n", content);
}

test "write over an existing file says so and diffs against the old content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    {
        var first = try runInTemp(gpa, io,
            \\{"path":"replace.txt","content":"before\n"}
        );
        first.deinit(gpa);
    }
    var output = try runInTemp(gpa, io,
        \\{"path":"replace.txt","content":"after\n"}
    );
    defer output.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "replaced existing file") != null);
    const diff = output.details_json.?;
    try std.testing.expect(std.mem.indexOf(u8, diff, "-1 before") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+1 after") != null);
}

test "write rejects a missing content field rather than truncating" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io,
        \\{"path":"guard.txt"}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "`content` is required") != null);
}

test "write refuses a path that escapes the project and creates nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const outside_rel = ".zig-cache/write-escape-target.txt";
    std.Io.Dir.cwd().deleteFile(io, outside_rel) catch {};

    var output = try runInTemp(gpa, io,
        \\{"path":"../write-escape-target.txt","content":"owned\n"}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "outside the workspace") != null);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, outside_rel, .{}),
    );
}
