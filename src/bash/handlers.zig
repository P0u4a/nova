const std = @import("std");
const parse = @import("parse.zig");

const assert = std.debug.assert;

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
} || std.Io.Cancelable || std.Io.UnexpectedError;

/// Returns true if we can run `simple` end-to-end ourselves. Validates
/// argv[0] is a known utility AND that all of its flags are ones we honor.
/// Redirects are validated separately by the dispatcher.
pub fn recognize(simple: parse.Simple) bool {
    if (simple.argv.len == 0) return false;
    const name = simple.argv[0];
    const rest = simple.argv[1..];
    if (eql(name, "cat")) return cat.recognize(rest);
    if (eql(name, "head")) return head.recognize(rest);
    if (eql(name, "tail")) return tail.recognize(rest);
    if (eql(name, "sed")) return sed.recognize(rest);
    if (eql(name, "ls")) return ls.recognize(rest);
    if (eql(name, "wc")) return wc.recognize(rest);
    return false;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    simple: parse.Simple,
    stdin: []const u8,
) Error!Output {
    assert(simple.argv.len > 0);
    const name = simple.argv[0];
    const rest = simple.argv[1..];
    if (eql(name, "cat")) return cat.run(gpa, io, cwd, rest, stdin);
    if (eql(name, "head")) return head.run(gpa, io, cwd, rest, stdin);
    if (eql(name, "tail")) return tail.run(gpa, io, cwd, rest, stdin);
    if (eql(name, "sed")) return sed.run(gpa, io, cwd, rest, stdin);
    if (eql(name, "ls")) return ls.run(gpa, io, cwd, rest, stdin);
    if (eql(name, "wc")) return wc.run(gpa, io, cwd, rest, stdin);
    unreachable; // recognize() must agree with run().
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn ok(gpa: std.mem.Allocator, stdout: []u8) Error!Output {
    return .{
        .stdout = stdout,
        .stderr = try gpa.alloc(u8, 0),
        .code = 0,
    };
}

fn fail(gpa: std.mem.Allocator, message: []const u8, code: u8) Error!Output {
    assert(code != 0);
    const stderr = try gpa.dupe(u8, message);
    errdefer gpa.free(stderr);
    return .{
        .stdout = try gpa.alloc(u8, 0),
        .stderr = stderr,
        .code = code,
    };
}

fn failFmt(
    gpa: std.mem.Allocator,
    code: u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!Output {
    assert(code != 0);
    const stderr = std.fmt.allocPrint(gpa, fmt, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer gpa.free(stderr);
    return .{
        .stdout = try gpa.alloc(u8, 0),
        .stderr = stderr,
        .code = code,
    };
}

const max_file_bytes: usize = 16 * 1024 * 1024;

/// Resolve `path` relative to `cwd` and return its byte contents. Caller owns the result.
fn readFileBytes(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8) ![]u8 {
    const absolute = try resolveAbsolute(gpa, cwd, path);
    defer gpa.free(absolute);
    var file = try std.Io.Dir.openFileAbsolute(io, absolute, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    return file_reader.interface.allocRemaining(gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn resolveAbsolute(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    assert(cwd.len > 0);
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ cwd, path });
}

/// Parse an integer argument. Returns null on malformed input.
fn parseCount(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

// ---------- cat ----------

const cat = struct {
    fn recognize(args: []const []const u8) bool {
        // No flags supported. Any token starting with `-` (other than the lone
        // `-` meaning stdin) is unknown — hand it back to bash.
        for (args) |arg| {
            if (arg.len >= 2 and arg[0] == '-') return false;
        }
        return true;
    }

    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const []const u8,
        stdin: []const u8,
    ) Error!Output {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        if (args.len == 0) {
            try buffer.appendSlice(gpa, stdin);
            return ok(gpa, try buffer.toOwnedSlice(gpa));
        }
        for (args) |arg| {
            if (arg.len == 1 and arg[0] == '-') {
                try buffer.appendSlice(gpa, stdin);
                continue;
            }
            const bytes = readFileBytes(gpa, io, cwd, arg) catch |err| {
                buffer.deinit(gpa);
                return failFmt(gpa, 1, "cat: {s}: {s}", .{ arg, errorMessage(err) });
            };
            defer gpa.free(bytes);
            try buffer.appendSlice(gpa, bytes);
        }
        return ok(gpa, try buffer.toOwnedSlice(gpa));
    }
};

// ---------- head ----------

const head = struct {
    const Mode = union(enum) { lines: u64, bytes: u64 };

    const default_mode: Mode = .{ .lines = 10 };

    fn recognize(args: []const []const u8) bool {
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (arg.len < 2 or arg[0] != '-') continue; // positional file.
            if (eql(arg, "--")) {
                index += 1;
                while (index < args.len) : (index += 1) {}
                return true;
            }
            if (eql(arg, "-n") or eql(arg, "-c")) {
                if (index + 1 >= args.len) return false;
                if (parseCount(args[index + 1]) == null) return false;
                index += 1;
                continue;
            }
            // Allow `-nN` / `-cN` glued forms.
            if (arg[1] == 'n' or arg[1] == 'c') {
                if (parseCount(arg[2..]) == null) return false;
                continue;
            }
            return false;
        }
        return true;
    }

    fn parseArgs(args: []const []const u8) struct { mode: Mode, files: []const []const u8 } {
        var mode: Mode = default_mode;
        var files_start: usize = args.len;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (arg.len < 2 or arg[0] != '-') {
                files_start = index;
                break;
            }
            if (eql(arg, "--")) {
                files_start = index + 1;
                break;
            }
            if (eql(arg, "-n")) {
                mode = .{ .lines = parseCount(args[index + 1]).? };
                index += 1;
                continue;
            }
            if (eql(arg, "-c")) {
                mode = .{ .bytes = parseCount(args[index + 1]).? };
                index += 1;
                continue;
            }
            if (arg[1] == 'n') {
                mode = .{ .lines = parseCount(arg[2..]).? };
                continue;
            }
            if (arg[1] == 'c') {
                mode = .{ .bytes = parseCount(arg[2..]).? };
                continue;
            }
            unreachable; // recognize() filtered this.
        }
        return .{ .mode = mode, .files = args[files_start..] };
    }

    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const []const u8,
        stdin: []const u8,
    ) Error!Output {
        const parsed = parseArgs(args);
        if (parsed.files.len == 0) {
            const slice = sliceHead(stdin, parsed.mode);
            return ok(gpa, try gpa.dupe(u8, slice));
        }
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        for (parsed.files) |file| {
            const bytes = readFileBytes(gpa, io, cwd, file) catch |err| {
                buffer.deinit(gpa);
                return failFmt(gpa, 1, "head: {s}: {s}", .{ file, errorMessage(err) });
            };
            defer gpa.free(bytes);
            try buffer.appendSlice(gpa, sliceHead(bytes, parsed.mode));
        }
        return ok(gpa, try buffer.toOwnedSlice(gpa));
    }

    fn sliceHead(bytes: []const u8, mode: Mode) []const u8 {
        switch (mode) {
            .bytes => |limit| {
                const take = if (limit < bytes.len) @as(usize, @intCast(limit)) else bytes.len;
                return bytes[0..take];
            },
            .lines => |limit| {
                if (limit == 0) return bytes[0..0];
                var seen: u64 = 0;
                var end: usize = 0;
                while (end < bytes.len) : (end += 1) {
                    if (bytes[end] == '\n') {
                        seen += 1;
                        if (seen == limit) {
                            end += 1;
                            return bytes[0..end];
                        }
                    }
                }
                return bytes;
            },
        }
    }
};

// ---------- tail ----------

const tail = struct {
    const Mode = union(enum) {
        last_lines: u64,
        from_line: u64, // 1-indexed; print lines starting at this number.
        last_bytes: u64,
    };

    const default_mode: Mode = .{ .last_lines = 10 };

    fn recognize(args: []const []const u8) bool {
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (arg.len < 2 or arg[0] != '-') continue;
            if (eql(arg, "--")) return true;
            if (eql(arg, "-n") or eql(arg, "-c")) {
                if (index + 1 >= args.len) return false;
                if (!validTailCount(args[index + 1], arg[1])) return false;
                index += 1;
                continue;
            }
            if (arg[1] == 'n' or arg[1] == 'c') {
                if (!validTailCount(arg[2..], arg[1])) return false;
                continue;
            }
            return false;
        }
        return true;
    }

    fn validTailCount(text: []const u8, flag: u8) bool {
        if (text.len == 0) return false;
        if (text[0] == '+') {
            if (flag != 'n') return false; // `-c +N` is undefined for us.
            return parseCount(text[1..]) != null;
        }
        return parseCount(text) != null;
    }

    fn parseArgs(args: []const []const u8) struct { mode: Mode, files: []const []const u8 } {
        var mode: Mode = default_mode;
        var files_start: usize = args.len;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (arg.len < 2 or arg[0] != '-') {
                files_start = index;
                break;
            }
            if (eql(arg, "--")) {
                files_start = index + 1;
                break;
            }
            const flag = arg[1];
            const text = if (eql(arg, "-n") or eql(arg, "-c")) blk: {
                index += 1;
                break :blk args[index];
            } else arg[2..];
            mode = makeMode(flag, text);
        }
        return .{ .mode = mode, .files = args[files_start..] };
    }

    fn makeMode(flag: u8, text: []const u8) Mode {
        if (flag == 'c') return .{ .last_bytes = parseCount(text).? };
        if (text[0] == '+') return .{ .from_line = parseCount(text[1..]).? };
        return .{ .last_lines = parseCount(text).? };
    }

    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const []const u8,
        stdin: []const u8,
    ) Error!Output {
        const parsed = parseArgs(args);
        if (parsed.files.len == 0) {
            const slice = sliceTail(stdin, parsed.mode);
            return ok(gpa, try gpa.dupe(u8, slice));
        }
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        for (parsed.files) |file| {
            const bytes = readFileBytes(gpa, io, cwd, file) catch |err| {
                buffer.deinit(gpa);
                return failFmt(gpa, 1, "tail: {s}: {s}", .{ file, errorMessage(err) });
            };
            defer gpa.free(bytes);
            try buffer.appendSlice(gpa, sliceTail(bytes, parsed.mode));
        }
        return ok(gpa, try buffer.toOwnedSlice(gpa));
    }

    fn sliceTail(bytes: []const u8, mode: Mode) []const u8 {
        switch (mode) {
            .last_bytes => |limit| {
                if (limit >= bytes.len) return bytes;
                const start = bytes.len - @as(usize, @intCast(limit));
                return bytes[start..];
            },
            .last_lines => |limit| return sliceLastLines(bytes, limit),
            .from_line => |first| return sliceFromLine(bytes, first),
        }
    }

    fn sliceLastLines(bytes: []const u8, limit: u64) []const u8 {
        if (limit == 0) return bytes[0..0];
        if (bytes.len == 0) return bytes;
        var newlines_seen: u64 = 0;
        var index: usize = bytes.len;
        const has_trailing_newline = bytes[bytes.len - 1] == '\n';
        if (has_trailing_newline) index -= 1;
        while (index > 0) {
            index -= 1;
            if (bytes[index] == '\n') {
                newlines_seen += 1;
                if (newlines_seen == limit) return bytes[index + 1 ..];
            }
        }
        return bytes;
    }

    fn sliceFromLine(bytes: []const u8, first: u64) []const u8 {
        if (first <= 1) return bytes;
        var current_line: u64 = 1;
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] == '\n') {
                current_line += 1;
                if (current_line == first) return bytes[index + 1 ..];
            }
        }
        return bytes[bytes.len..];
    }
};

// ---------- sed (only `-n 'A,Bp'` etc.) ----------

const sed = struct {
    const Range = struct {
        start: u64, // 1-indexed inclusive.
        end: ?u64, // null = `$` (end of file).
    };

    fn recognize(args: []const []const u8) bool {
        // Exactly `-n`, then expr, then one filename. No other flags.
        if (args.len != 3) return false;
        if (!eql(args[0], "-n")) return false;
        return parseExpr(args[1]) != null;
    }

    fn parseExpr(expr: []const u8) ?Range {
        if (expr.len < 2) return null;
        if (expr[expr.len - 1] != 'p') return null;
        const body = expr[0 .. expr.len - 1];
        const comma = std.mem.indexOfScalar(u8, body, ',');
        if (comma == null) {
            const single = parseCount(body) orelse return null;
            if (single == 0) return null;
            return .{ .start = single, .end = single };
        }
        const start_text = body[0..comma.?];
        const end_text = body[comma.? + 1 ..];
        const start = parseCount(start_text) orelse return null;
        if (start == 0) return null;
        if (eql(end_text, "$")) return .{ .start = start, .end = null };
        const end = parseCount(end_text) orelse return null;
        if (end == 0 or end < start) return null;
        return .{ .start = start, .end = end };
    }

    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const []const u8,
        _: []const u8,
    ) Error!Output {
        assert(args.len == 3);
        const range = parseExpr(args[1]).?;
        const file = args[2];
        const bytes = readFileBytes(gpa, io, cwd, file) catch |err| {
            return failFmt(gpa, 1, "sed: {s}: {s}", .{ file, errorMessage(err) });
        };
        defer gpa.free(bytes);
        const slice = sliceRange(bytes, range);
        return ok(gpa, try gpa.dupe(u8, slice));
    }

    fn sliceRange(bytes: []const u8, range: Range) []const u8 {
        var line: u64 = 1;
        var start_byte: usize = 0;
        while (line < range.start and start_byte < bytes.len) {
            if (bytes[start_byte] == '\n') line += 1;
            start_byte += 1;
        }
        if (line < range.start) return bytes[bytes.len..];
        const end_byte = if (range.end) |last| findLineEnd(bytes, start_byte, line, last) else bytes.len;
        return bytes[start_byte..end_byte];
    }

    fn findLineEnd(bytes: []const u8, from: usize, from_line: u64, last_line: u64) usize {
        var line: u64 = from_line;
        var index: usize = from;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] == '\n') {
                if (line == last_line) return index + 1;
                line += 1;
            }
        }
        return bytes.len;
    }
};

// ---------- ls ----------

const ls = struct {
    const Flags = struct {
        show_hidden: bool = false, // -a (includes . and ..), -A (hides . and ..)
        with_dot_entries: bool = false, // -a adds . and ..
        mark_directories: bool = false, // -p
        // `-1` is implicit: we always print one entry per line.
    };

    fn recognize(args: []const []const u8) bool {
        for (args) |arg| {
            if (arg.len == 0) return false;
            if (arg[0] != '-' or arg.len == 1) continue; // positional path.
            if (eql(arg, "--")) continue;
            for (arg[1..]) |c| {
                if (c != 'a' and c != 'A' and c != '1' and c != 'p') return false;
            }
        }
        return true;
    }

    fn parseArgs(args: []const []const u8) struct { flags: Flags, path: []const u8 } {
        var flags: Flags = .{};
        var path: []const u8 = ".";
        for (args) |arg| {
            if (eql(arg, "--")) continue;
            if (arg.len >= 2 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'a' => {
                            flags.show_hidden = true;
                            flags.with_dot_entries = true;
                        },
                        'A' => flags.show_hidden = true,
                        'p' => flags.mark_directories = true,
                        '1' => {}, // one-per-line is our default.
                        else => unreachable, // recognize() filtered this.
                    }
                }
                continue;
            }
            path = arg;
        }
        return .{ .flags = flags, .path = path };
    }

    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const []const u8,
        _: []const u8,
    ) Error!Output {
        const parsed = parseArgs(args);
        const absolute = try resolveAbsolute(gpa, cwd, parsed.path);
        defer gpa.free(absolute);
        var dir = std.Io.Dir.openDirAbsolute(io, absolute, .{ .iterate = true }) catch |err| {
            return failFmt(gpa, 1, "ls: {s}: {s}", .{ parsed.path, errorMessage(err) });
        };
        defer dir.close(io);

        var entries: std.ArrayList(Entry) = .empty;
        defer freeEntries(gpa, &entries);

        var iter = dir.iterate();
        while (true) {
            const maybe_entry = iter.next(io) catch |err| {
                return failFmt(gpa, 1, "ls: {s}: {s}", .{ parsed.path, errorMessage(err) });
            };
            const entry = maybe_entry orelse break;
            if (!parsed.flags.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            const owned_name = try gpa.dupe(u8, entry.name);
            try entries.append(gpa, .{ .name = owned_name, .is_directory = entry.kind == .directory });
        }
        if (parsed.flags.with_dot_entries) {
            try entries.append(gpa, .{ .name = try gpa.dupe(u8, "."), .is_directory = true });
            try entries.append(gpa, .{ .name = try gpa.dupe(u8, ".."), .is_directory = true });
        }

        std.mem.sort(Entry, entries.items, {}, Entry.lessThan);

        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        for (entries.items) |entry| {
            try buffer.appendSlice(gpa, entry.name);
            if (parsed.flags.mark_directories and entry.is_directory) try buffer.append(gpa, '/');
            try buffer.append(gpa, '\n');
        }
        return ok(gpa, try buffer.toOwnedSlice(gpa));
    }

    const Entry = struct {
        name: []u8,
        is_directory: bool,

        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return compareAsciiCaseInsensitive(a.name, b.name) == .lt;
        }
    };

    fn freeEntries(gpa: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
        for (entries.items) |entry| gpa.free(entry.name);
        entries.deinit(gpa);
    }
};

fn compareAsciiCaseInsensitive(a: []const u8, b: []const u8) std.math.Order {
    const shorter = if (a.len < b.len) a.len else b.len;
    var i: usize = 0;
    while (i < shorter) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca < cb) return .lt;
        if (ca > cb) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

// ---------- wc ----------

const wc = struct {
    const Mode = enum { lines, bytes };

    fn recognize(args: []const []const u8) bool {
        var saw_mode = false;
        for (args) |arg| {
            if (arg.len < 2 or arg[0] != '-') continue;
            if (eql(arg, "--")) continue;
            for (arg[1..]) |c| {
                if (c != 'l' and c != 'c') return false;
                saw_mode = true;
            }
        }
        return saw_mode;
    }

    fn parseArgs(args: []const []const u8) struct { mode: Mode, files: []const []const u8 } {
        var mode: Mode = .lines;
        var files_start: usize = args.len;
        var positional_index: usize = 0;
        for (args, 0..) |arg, index| {
            if (eql(arg, "--")) {
                files_start = index + 1;
                break;
            }
            if (arg.len >= 2 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'l' => mode = .lines,
                        'c' => mode = .bytes,
                        else => unreachable,
                    }
                }
                continue;
            }
            if (positional_index == 0) files_start = index;
            positional_index += 1;
        }
        return .{ .mode = mode, .files = args[files_start..] };
    }

    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const []const u8,
        stdin: []const u8,
    ) Error!Output {
        const parsed = parseArgs(args);
        if (parsed.files.len == 0) {
            const count = countBytes(stdin, parsed.mode);
            const text = try std.fmt.allocPrint(gpa, "{d}\n", .{count});
            return ok(gpa, text);
        }
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        for (parsed.files) |file| {
            const bytes = readFileBytes(gpa, io, cwd, file) catch |err| {
                buffer.deinit(gpa);
                return failFmt(gpa, 1, "wc: {s}: {s}", .{ file, errorMessage(err) });
            };
            defer gpa.free(bytes);
            const count = countBytes(bytes, parsed.mode);
            try buffer.print(gpa, "{d} {s}\n", .{ count, file });
        }
        return ok(gpa, try buffer.toOwnedSlice(gpa));
    }

    fn countBytes(bytes: []const u8, mode: Mode) u64 {
        switch (mode) {
            .bytes => return @as(u64, bytes.len),
            .lines => {
                var count: u64 = 0;
                for (bytes) |c| {
                    if (c == '\n') count += 1;
                }
                return count;
            },
        }
    }
};

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.StreamTooLong => "File too large",
        else => @errorName(err),
    };
}

test "cat with stdin and no args is identity" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{"cat"};
    var output = try run(gpa, std.testing.io, ".", .{
        .argv = &argv,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }, "piped bytes\n");
    defer output.deinit(gpa);
    try std.testing.expectEqualStrings("piped bytes\n", output.stdout);
}

test "head -n 2 trims lines" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{ "head", "-n", "2" };
    var output = try run(gpa, std.testing.io, ".", .{
        .argv = &argv,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }, "a\nb\nc\nd\n");
    defer output.deinit(gpa);
    try std.testing.expectEqualStrings("a\nb\n", output.stdout);
}

test "tail -n 2 keeps last lines" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{ "tail", "-n", "2" };
    var output = try run(gpa, std.testing.io, ".", .{
        .argv = &argv,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }, "a\nb\nc\nd\n");
    defer output.deinit(gpa);
    try std.testing.expectEqualStrings("c\nd\n", output.stdout);
}

test "tail -n +2 starts at line two" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{ "tail", "-n", "+2" };
    var output = try run(gpa, std.testing.io, ".", .{
        .argv = &argv,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }, "a\nb\nc\n");
    defer output.deinit(gpa);
    try std.testing.expectEqualStrings("b\nc\n", output.stdout);
}

test "sed expression parser accepts our supported forms" {
    try std.testing.expect(sed.parseExpr("2,3p") != null);
    try std.testing.expect(sed.parseExpr("5p") != null);
    try std.testing.expect(sed.parseExpr("10,$p") != null);
    try std.testing.expect(sed.parseExpr("0p") == null);
    try std.testing.expect(sed.parseExpr("5,2p") == null);
    try std.testing.expect(sed.parseExpr("foo") == null);
}

test "sed sliceRange selects a closed range" {
    const bytes = "1\n2\n3\n4\n5\n";
    const slice = sed.sliceRange(bytes, .{ .start = 2, .end = 3 });
    try std.testing.expectEqualStrings("2\n3\n", slice);
}

test "wc -l counts piped lines" {
    const gpa = std.testing.allocator;
    var argv = [_][]const u8{ "wc", "-l" };
    var output = try run(gpa, std.testing.io, ".", .{
        .argv = &argv,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }, "one\ntwo\nthree\n");
    defer output.deinit(gpa);
    try std.testing.expectEqualStrings("3\n", output.stdout);
}

test "ls sort is case-insensitive" {
    try std.testing.expectEqual(std.math.Order.lt, compareAsciiCaseInsensitive("apple", "Banana"));
    try std.testing.expectEqual(std.math.Order.gt, compareAsciiCaseInsensitive("Cherry", "Banana"));
    try std.testing.expectEqual(std.math.Order.eq, compareAsciiCaseInsensitive("Apple", "apple"));
}

test "recognize rejects unknown flags" {
    var argv1 = [_][]const u8{ "cat", "-n", "foo.txt" };
    try std.testing.expect(!recognize(.{
        .argv = &argv1,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }));
    var argv2 = [_][]const u8{ "ls", "-l" };
    try std.testing.expect(!recognize(.{
        .argv = &argv2,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }));
    var argv3 = [_][]const u8{ "head", "-n", "5", "foo.txt" };
    try std.testing.expect(recognize(.{
        .argv = &argv3,
        .redirects = &.{},
        .span_start = 0,
        .span_end = 0,
    }));
}
