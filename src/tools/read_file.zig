const std = @import("std");
const common = @import("common.zig");
const hashline = @import("hashline/hash.zig");

const max_file_bytes: usize = 16 * 1024 * 1024;
const max_output_lines: u32 = 2000;
const max_output_bytes: usize = 50 * 1024;

const Args = struct {
    path: []const u8,
    offset: u32 = 1,
    limit: ?u32 = null,
};

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch {
        return common.fail(gpa, "read_file: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const args = parseToolArgs(gpa, parsed.value) catch |err| return parseToolError(gpa, err);
    return read(gpa, io, cwd, args);
}

const ParseToolError = error{ MissingPath, BadPath, BadOffset, BadLimit, OutOfMemory };

fn parseToolArgs(gpa: std.mem.Allocator, value: std.json.Value) ParseToolError!Args {
    _ = gpa;
    const path = value.object.get("path") orelse return ParseToolError.MissingPath;
    if (path != .string) return ParseToolError.BadPath;
    var args: Args = .{ .path = path.string };
    if (value.object.get("offset")) |offset| {
        if (offset != .integer) return ParseToolError.BadOffset;
        if (offset.integer < 1) return ParseToolError.BadOffset;
        args.offset = std.math.cast(u32, offset.integer) orelse return ParseToolError.BadOffset;
    }
    if (value.object.get("limit")) |limit| {
        if (limit != .integer) return ParseToolError.BadLimit;
        if (limit.integer < 0) return ParseToolError.BadLimit;
        args.limit = std.math.cast(u32, limit.integer) orelse return ParseToolError.BadLimit;
    }
    return args;
}

fn parseToolError(gpa: std.mem.Allocator, err: ParseToolError) common.Error!common.Output {
    const message = switch (err) {
        ParseToolError.MissingPath => "read_file: missing path\n",
        ParseToolError.BadPath => "read_file: path must be a string\n",
        ParseToolError.BadOffset => "read_file: offset must be a positive integer\n",
        ParseToolError.BadLimit => "read_file: limit must be a non-negative integer\n",
        ParseToolError.OutOfMemory => return error.OutOfMemory,
    };
    return common.fail(gpa, message, 2);
}

fn read(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, args: Args) common.Error!common.Output {
    const absolute = joinPath(gpa, cwd, args.path) catch |err| return mapAllocError(err);
    defer gpa.free(absolute);

    const bytes = readFileBytes(gpa, io, absolute) catch |err| {
        return common.failFmt(gpa, 1, "read_file: {s}: {s}\n", .{ args.path, @errorName(err) });
    };
    defer gpa.free(bytes);

    return formatOutput(gpa, args, bytes);
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

fn joinPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ cwd, path });
}

fn mapAllocError(err: anyerror) common.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

fn formatOutput(gpa: std.mem.Allocator, args: Args, bytes: []const u8) common.Error!common.Output {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line| try lines.append(gpa, line);
    const total_lines: u32 = @intCast(lines.items.len);

    if (args.offset > total_lines) {
        return common.failFmt(gpa, 2, "read_file: offset {d} is past end of file ({d} lines)\n", .{ args.offset, total_lines });
    }

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    var emitted: u32 = 0;
    var line_number = args.offset;
    const stop_at = chooseStop(args, total_lines);
    while (line_number <= stop_at) : (line_number += 1) {
        const new_size = buffer.items.len + estimateLineCost(line_number, lines.items[line_number - 1]);
        if (emitted > 0 and new_size > max_output_bytes) break;
        if (emitted > 0) try buffer.append(gpa, '\n');
        try hashline.writeHashLine(gpa, &buffer, line_number, lines.items[line_number - 1]);
        emitted += 1;
        if (emitted >= max_output_lines) break;
    }
    try appendFooter(gpa, &buffer, args, total_lines, line_number, emitted);
    return common.ok(gpa, try buffer.toOwnedSlice(gpa));
}

fn chooseStop(args: Args, total_lines: u32) u32 {
    if (args.limit) |limit| {
        if (limit == 0) return args.offset - 1;
        const candidate = args.offset + limit - 1;
        return @min(candidate, total_lines);
    }
    return total_lines;
}

fn estimateLineCost(line_number: u32, line: []const u8) usize {
    var digits: usize = 1;
    var n = line_number;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits + 2 + 1 + line.len + 1;
}

fn appendFooter(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    args: Args,
    total_lines: u32,
    next_line: u32,
    emitted: u32,
) common.Error!void {
    if (next_line > total_lines) return;
    if (args.limit) |_| {
        try buffer.print(gpa, "\n\n[Showing lines {d}-{d} of {d}. Use offset {d} to continue.]", .{
            args.offset, args.offset + emitted - 1, total_lines, next_line,
        });
        return;
    }
    try buffer.print(gpa, "\n\n[Showing lines {d}-{d} of {d} (truncated at {d} lines / {d}KB). Use offset {d} to continue.]", .{
        args.offset, args.offset + emitted - 1, total_lines, max_output_lines, max_output_bytes / 1024, next_line,
    });
}

test "read_file missing path is a usage error" {
    var output = try runTool(std.testing.allocator, std.testing.io, ".", "{}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing path") != null);
}
