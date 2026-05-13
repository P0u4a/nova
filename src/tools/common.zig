const std = @import("std");

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

/// Detect a `--help` or `-h` flag anywhere in argv. If present, the tool's
/// run function should short-circuit and emit its help_text via `helpOutput`.
pub fn wantsHelp(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--help")) return true;
        if (std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

pub fn helpOutput(gpa: std.mem.Allocator, text: []const u8) Error!Output {
    const stdout = try gpa.dupe(u8, text);
    errdefer gpa.free(stdout);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0 };
}

pub fn ok(gpa: std.mem.Allocator, stdout: []u8) Error!Output {
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0 };
}

pub fn fail(gpa: std.mem.Allocator, message: []const u8, code: u8) Error!Output {
    assert(code != 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try gpa.dupe(u8, message);
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

pub fn failFmt(
    gpa: std.mem.Allocator,
    code: u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!Output {
    assert(code != 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try std.fmt.allocPrint(gpa, fmt, args);
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

test "wantsHelp finds long and short forms" {
    var argv1 = [_][]const u8{ "read-file", "--help" };
    try std.testing.expect(wantsHelp(&argv1));
    var argv2 = [_][]const u8{ "read-file", "-h" };
    try std.testing.expect(wantsHelp(&argv2));
    var argv3 = [_][]const u8{ "read-file", "foo.zig" };
    try std.testing.expect(!wantsHelp(&argv3));
}

test "helpOutput returns help text on stdout with code 0" {
    var output = try helpOutput(std.testing.allocator, "Usage: foo");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Usage: foo", output.stdout);
    try std.testing.expectEqual(@as(u8, 0), output.code);
}
