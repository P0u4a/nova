const std = @import("std");
const common = @import("common.zig");
const apply_mod = @import("hashline/apply.zig");
const parse_mod = @import("hashline/parse.zig");

pub const name = "edit-file";

pub const help_text =
    \\Usage: edit-file PATH
    \\
    \\Reads a hashline patch on stdin and applies it to PATH. Each
    \\anchor (`LINE+HASH`) is validated against the current file; if
    \\any hash has changed since the last read, the patch is rejected
    \\and you must re-read.
    \\
    \\Patch operations (each on its own line):
    \\  < ANCHOR        insert lines before ANCHOR (payload follows)
    \\  + ANCHOR        insert lines after ANCHOR (payload follows)
    \\  = A..B          replace lines A through B with payload
    \\  - A..B          delete lines A through B
    \\  ~TEXT           payload line (for <, +, = operations)
    \\
    \\Special anchors: BOF (before file), EOF (after file).
    \\
    \\Options:
    \\  --help          show this message
;

const max_file_bytes: usize = 16 * 1024 * 1024;

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    stdin: []const u8,
) common.Error!common.Output {
    if (common.wantsHelp(argv)) return common.helpOutput(gpa, help_text);

    const path = firstPositional(argv) orelse {
        return common.fail(gpa, "edit-file: missing PATH argument\n", 2);
    };
    if (stdin.len == 0) {
        return common.fail(gpa, "edit-file: empty patch on stdin\n", 2);
    }

    const absolute = joinPath(gpa, cwd, path) catch |err| return mapAllocError(err);
    defer gpa.free(absolute);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const edits = parse_mod.parse(arena_state.allocator(), stdin) catch |err| {
        return common.failFmt(gpa, 2, "edit-file: invalid patch: {s}\n", .{@errorName(err)});
    };

    const original = readFileBytes(gpa, io, absolute) catch |err| {
        return common.failFmt(gpa, 1, "edit-file: cannot read {s}: {s}\n", .{ path, @errorName(err) });
    };
    defer gpa.free(original);

    const outcome = apply_mod.apply(gpa, original, edits) catch |err| {
        return common.failFmt(gpa, 1, "edit-file: apply failed: {s}\n", .{@errorName(err)});
    };
    return finalize(gpa, io, path, absolute, outcome);
}

fn finalize(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    absolute: []const u8,
    outcome: apply_mod.Outcome,
) common.Error!common.Output {
    switch (outcome) {
        .rejected => |mismatches| {
            defer gpa.free(mismatches);
            return formatRejection(gpa, path, mismatches);
        },
        .applied => |applied| {
            defer gpa.free(applied.content);
            writeBack(io, absolute, applied.content) catch |err| {
                return common.failFmt(gpa, 1, "edit-file: write to {s} failed: {s}\n", .{ path, @errorName(err) });
            };
            const first = applied.first_changed_line orelse 0;
            const message = std.fmt.allocPrint(gpa, "Edit applied to {s} (first changed line: {d}).\n", .{ path, first }) catch |err| return mapAllocError(err);
            return common.ok(gpa, message);
        },
    }
}

fn formatRejection(
    gpa: std.mem.Allocator,
    path: []const u8,
    mismatches: []const apply_mod.Mismatch,
) common.Error!common.Output {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    try buffer.print(gpa, "edit-file: {s} has changed since the last read; re-read and retry. Mismatches:\n", .{path});
    for (mismatches) |m| {
        try buffer.print(gpa, "  line {d}: expected {s}, got {s}\n", .{ m.line, &m.expected, &m.actual });
    }
    return .{
        .stdout = try gpa.alloc(u8, 0),
        .stderr = try buffer.toOwnedSlice(gpa),
        .code = 1,
    };
}

fn writeBack(io: std.Io, absolute: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, absolute, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn readFileBytes(gpa: std.mem.Allocator, io: std.Io, absolute: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, absolute, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn firstPositional(argv: []const []const u8) ?[]const u8 {
    for (argv) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] != '-') return arg;
    }
    return null;
}

fn joinPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ cwd, path });
}

fn mapAllocError(err: anyerror) common.Error {
    return switch (err) {
        error.OutOfMemory => common.Error.OutOfMemory,
        else => common.Error.Unexpected,
    };
}

test "edit-file --help returns the help text" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{"--help"};
    var output = try run(gpa, std.testing.io, ".", &argv, "");
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "edit-file") != null);
}

test "edit-file rejects empty stdin" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{"foo.zig"};
    var output = try run(gpa, std.testing.io, ".", &argv, "");
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "empty patch") != null);
}
