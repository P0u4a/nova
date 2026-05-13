const std = @import("std");
const common = @import("common.zig");
const hashline = @import("hashline/hash.zig");

pub const name = "read-file";

pub const help_text =
    \\Usage: read-file [--offset N] [--limit N] PATH
    \\
    \\Prints file content. Output is truncated to 2000
    \\lines or 50KB; the truncation footer shows the next --offset to
    \\continue.
    \\Each line is prefixed with `LINE+HASH|TEXT` anchors that edit-file consumes
    \\Options:
    \\  --offset N   start at line N (1-indexed, default 1)
    \\  --limit N    print at most N lines (otherwise truncate at the
    \\               2000-line / 50KB cap)
    \\  --help       show this message
;

const max_file_bytes: usize = 16 * 1024 * 1024;
const max_output_lines: u32 = 2000;
const max_output_bytes: usize = 50 * 1024;

const Args = struct {
    path: []const u8,
    offset: u32 = 1,
    limit: ?u32 = null,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    stdin: []const u8,
) common.Error!common.Output {
    _ = stdin;
    if (common.wantsHelp(argv)) return common.helpOutput(gpa, help_text);

    const args = parseArgs(argv) catch |err| return parseError(gpa, err);
    const absolute = joinPath(gpa, cwd, args.path) catch |err| return mapAllocError(err);
    defer gpa.free(absolute);

    const bytes = readFileBytes(gpa, io, absolute) catch |err| {
        return common.failFmt(gpa, 1, "read-file: {s}: {s}\n", .{ args.path, @errorName(err) });
    };
    defer gpa.free(bytes);

    return formatOutput(gpa, args, bytes);
}

const ParseError = error{ MissingPath, BadOffset, BadLimit, UnknownFlag };

fn parseArgs(argv: []const []const u8) ParseError!Args {
    var args: Args = .{ .path = "" };
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--offset")) {
            if (index + 1 >= argv.len) return ParseError.BadOffset;
            args.offset = std.fmt.parseInt(u32, argv[index + 1], 10) catch return ParseError.BadOffset;
            if (args.offset == 0) return ParseError.BadOffset;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (index + 1 >= argv.len) return ParseError.BadLimit;
            args.limit = std.fmt.parseInt(u32, argv[index + 1], 10) catch return ParseError.BadLimit;
            index += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return ParseError.UnknownFlag;
        if (args.path.len > 0) continue;
        args.path = arg;
    }
    if (args.path.len == 0) return ParseError.MissingPath;
    return args;
}

fn parseError(gpa: std.mem.Allocator, err: ParseError) common.Error!common.Output {
    const message = switch (err) {
        ParseError.MissingPath => "read-file: missing PATH argument\n",
        ParseError.BadOffset => "read-file: --offset must be a positive integer\n",
        ParseError.BadLimit => "read-file: --limit must be a non-negative integer\n",
        ParseError.UnknownFlag => "read-file: unknown flag (try --help)\n",
    };
    return common.fail(gpa, message, 2);
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
        error.OutOfMemory => common.Error.OutOfMemory,
        else => common.Error.Unexpected,
    };
}

fn formatOutput(gpa: std.mem.Allocator, args: Args, bytes: []const u8) common.Error!common.Output {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var iter = std.mem.splitScalar(u8, bytes, '\n');
    while (iter.next()) |line| try lines.append(gpa, line);
    const total_lines: u32 = @intCast(lines.items.len);

    if (args.offset > total_lines) {
        return common.failFmt(gpa, 2, "read-file: --offset {d} is past end of file ({d} lines)\n", .{ args.offset, total_lines });
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
        const candidate = args.offset + limit - 1;
        if (limit == 0) return args.offset - 1; // empty output
        return @min(candidate, total_lines);
    }
    return total_lines;
}

fn estimateLineCost(line_number: u32, line: []const u8) usize {
    var digits: usize = 1;
    var n = line_number;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits + 2 + 1 + line.len + 1; // <num><hash>|<text>\n
}

fn appendFooter(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    args: Args,
    total_lines: u32,
    next_line: u32,
    emitted: u32,
) common.Error!void {
    if (next_line > total_lines) return; // showed everything we asked for
    if (args.limit) |_| {
        // User-set limit reached but file has more.
        try buffer.print(gpa, "\n\n[Showing lines {d}-{d} of {d}. Use --offset {d} to continue.]", .{
            args.offset, args.offset + emitted - 1, total_lines, next_line,
        });
        return;
    }
    try buffer.print(gpa, "\n\n[Showing lines {d}-{d} of {d} (truncated at {d} lines / {d}KB). Use --offset {d} to continue.]", .{
        args.offset, args.offset + emitted - 1, total_lines, max_output_lines, max_output_bytes / 1024, next_line,
    });
}

test "read-file --help returns the help text" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{"--help"};
    var output = try run(gpa, std.testing.io, ".", &argv, "");
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "read-file") != null);
}

test "read-file missing path is a usage error" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{};
    var output = try run(gpa, std.testing.io, ".", &argv, "");
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing PATH") != null);
}

test "parseArgs reads offset and limit" {
    var argv = [_][]const u8{ "--offset", "5", "--limit", "20", "foo.zig" };
    const parsed = try parseArgs(&argv);
    try std.testing.expectEqual(@as(u32, 5), parsed.offset);
    try std.testing.expectEqual(@as(?u32, 20), parsed.limit);
    try std.testing.expectEqualStrings("foo.zig", parsed.path);
}
