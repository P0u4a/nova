const std = @import("std");
const common = @import("common.zig");

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch {
        return common.fail(gpa, "write_file: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const path = parsed.value.object.get("path") orelse return common.fail(gpa, "write_file: missing path\n", 2);
    const content = parsed.value.object.get("content") orelse return common.fail(gpa, "write_file: missing content\n", 2);
    if (path != .string) return common.fail(gpa, "write_file: path must be a string\n", 2);
    if (content != .string) return common.fail(gpa, "write_file: content must be a string\n", 2);
    return write(gpa, io, cwd, path.string, content.string);
}

fn write(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8, content: []const u8) common.Error!common.Output {
    const absolute = joinPath(gpa, cwd, path) catch |err| return mapAllocError(err);
    defer gpa.free(absolute);

    if (std.fs.path.dirname(absolute)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
            return common.failFmt(gpa, 1, "write_file: cannot create parent of {s}: {s}\n", .{ path, @errorName(err) });
        };
    }

    var file = std.Io.Dir.createFileAbsolute(io, absolute, .{ .truncate = true }) catch |err| {
        return common.failFmt(gpa, 1, "write_file: cannot open {s}: {s}\n", .{ path, @errorName(err) });
    };
    defer file.close(io);
    file.writeStreamingAll(io, content) catch |err| {
        return common.failFmt(gpa, 1, "write_file: write to {s} failed: {s}\n", .{ path, @errorName(err) });
    };

    const message = std.fmt.allocPrint(gpa, "Successfully wrote {d} bytes to {s}\n", .{ content.len, path }) catch |err| return mapAllocError(err);
    return common.ok(gpa, message);
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

test "write_file requires a path" {
    var output = try runTool(std.testing.allocator, std.testing.io, ".", "{\"content\":\"data\"}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing path") != null);
}
