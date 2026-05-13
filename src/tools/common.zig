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
