const std = @import("std");
const common = @import("common.zig");
const apply_mod = @import("hashline/apply.zig");
const parse_mod = @import("hashline/parse.zig");

const max_file_bytes: usize = 16 * 1024 * 1024;

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch {
        return common.fail(gpa, "edit_file: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const input = parsed.value.object.get("input") orelse return common.fail(gpa, "edit_file: missing input\n", 2);
    if (input != .string) return common.fail(gpa, "edit_file: input must be a string\n", 2);
    return runPatchDocument(gpa, io, cwd, input.string);
}

const Section = struct {
    path: []const u8,
    diff: []u8,

    fn deinit(self: *Section, gpa: std.mem.Allocator) void {
        gpa.free(self.diff);
        self.* = undefined;
    }
};

fn runPatchDocument(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, input: []const u8) common.Error!common.Output {
    var sections = parseSections(gpa, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.failFmt(gpa, 2, "edit_file: invalid patch document: {s}\n", .{@errorName(err)}),
    };
    defer {
        for (sections.items) |*section| section.deinit(gpa);
        sections.deinit(gpa);
    }
    if (sections.items.len == 0) return common.fail(gpa, "edit_file: patch document must include @@ PATH\n", 2);

    var stdout_buffer: std.ArrayList(u8) = .empty;
    errdefer stdout_buffer.deinit(gpa);
    var stderr_buffer: std.ArrayList(u8) = .empty;
    errdefer stderr_buffer.deinit(gpa);
    var final_code: u8 = 0;

    for (sections.items) |section| {
        var output = try runSingle(gpa, io, cwd, section.path, section.diff);
        defer output.deinit(gpa);
        try stdout_buffer.appendSlice(gpa, output.stdout);
        try stderr_buffer.appendSlice(gpa, output.stderr);
        if (output.code != 0) final_code = output.code;
        if (output.code != 0) break;
    }

    return .{
        .stdout = try stdout_buffer.toOwnedSlice(gpa),
        .stderr = try stderr_buffer.toOwnedSlice(gpa),
        .code = final_code,
    };
}

const SectionParseError = error{MissingHeader} || std.mem.Allocator.Error;

fn parseSections(gpa: std.mem.Allocator, input: []const u8) SectionParseError!std.ArrayList(Section) {
    var sections: std.ArrayList(Section) = .empty;
    errdefer {
        for (sections.items) |*section| section.deinit(gpa);
        sections.deinit(gpa);
    }

    var current_path: ?[]const u8 = null;
    var current_diff: std.ArrayList(u8) = .empty;
    errdefer current_diff.deinit(gpa);

    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |raw_line| {
        const line = trimTrailingCR(raw_line);
        const control_line = std.mem.trimStart(u8, line, " \t");
        if (isEnvelopeLine(control_line)) continue;
        if (parseHeader(control_line)) |path| {
            if (current_path) |existing_path| {
                try sections.append(gpa, .{ .path = existing_path, .diff = try current_diff.toOwnedSlice(gpa) });
                current_diff = .empty;
            }
            current_path = path;
            continue;
        }
        if (current_path == null) {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            return SectionParseError.MissingHeader;
        }
        try current_diff.appendSlice(gpa, raw_line);
        try current_diff.append(gpa, '\n');
    }

    if (current_path) |path| {
        try sections.append(gpa, .{ .path = path, .diff = try current_diff.toOwnedSlice(gpa) });
        current_diff = .empty;
    }
    return sections;
}

fn parseHeader(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const path = std.mem.trim(u8, line[2..], " \t");
    if (path.len == 0) return null;
    return path;
}

fn isEnvelopeLine(line: []const u8) bool {
    if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "*** Begin Patch")) return true;
    if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "*** End Patch")) return true;
    return false;
}

fn trimTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn runSingle(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8, stdin: []const u8) common.Error!common.Output {
    const absolute = joinPath(gpa, cwd, path) catch |err| return mapAllocError(err);
    defer gpa.free(absolute);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const edits = parse_mod.parse(arena_state.allocator(), stdin) catch |err| {
        return common.failFmt(gpa, 2, "edit_file: invalid patch: {s}\n", .{@errorName(err)});
    };

    const original = readFileBytes(gpa, io, absolute) catch |err| {
        return common.failFmt(gpa, 1, "edit_file: cannot read {s}: {s}\n", .{ path, @errorName(err) });
    };
    defer gpa.free(original);

    const outcome = apply_mod.apply(gpa, original, edits) catch |err| {
        return common.failFmt(gpa, 1, "edit_file: apply failed: {s}\n", .{@errorName(err)});
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
                return common.failFmt(gpa, 1, "edit_file: write to {s} failed: {s}\n", .{ path, @errorName(err) });
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
    try buffer.print(gpa, "edit_file: {s} has changed since the last read; re-read and retry. Mismatches:\n", .{path});
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

test "edit_file requires an input document" {
    var output = try runTool(std.testing.allocator, std.testing.io, ".", "{}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "missing input") != null);
}
