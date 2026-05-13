const std = @import("std");
const common = @import("common.zig");

pub const name = "write-file";

pub const help_text =
    \\Usage: write-file PATH
    \\
    \\Reads stdin and writes it to PATH, creating parent directories
    \\as needed. Use for new files or full rewrites. For targeted changes 
    \\to an existing file, use edit-file
    \\
    \\Options:
    \\  --help       show this message
;

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    stdin: []const u8,
) common.Error!common.Output {
    if (common.wantsHelp(argv)) return common.helpOutput(gpa, help_text);

    const path = firstPositional(argv) orelse {
        return common.fail(gpa, "write-file: missing PATH argument\n", 2);
    };

    const absolute = joinPath(gpa, cwd, path) catch |err| return mapAllocError(err);
    defer gpa.free(absolute);

    if (std.fs.path.dirname(absolute)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
            return common.failFmt(gpa, 1, "write-file: cannot create parent of {s}: {s}\n", .{ path, @errorName(err) });
        };
    }

    var file = std.Io.Dir.createFileAbsolute(io, absolute, .{ .truncate = true }) catch |err| {
        return common.failFmt(gpa, 1, "write-file: cannot open {s}: {s}\n", .{ path, @errorName(err) });
    };
    defer file.close(io);
    file.writeStreamingAll(io, stdin) catch |err| {
        return common.failFmt(gpa, 1, "write-file: write to {s} failed: {s}\n", .{ path, @errorName(err) });
    };

    const message = std.fmt.allocPrint(gpa, "Successfully wrote {d} bytes to {s}\n", .{ stdin.len, path }) catch |err| return mapAllocError(err);
    return common.ok(gpa, message);
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

test "write-file requires a path" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{};
    var output = try run(gpa, std.testing.io, ".", &argv, "data");
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing PATH") != null);
}

test "write-file --help returns the help text" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{"--help"};
    var output = try run(gpa, std.testing.io, ".", &argv, "");
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "write-file") != null);
}
