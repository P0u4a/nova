const std = @import("std");

const assert = std.debug.assert;

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    display: ?[]u8 = null,

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        if (self.display) |display| gpa.free(display);
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
} || std.Io.Cancelable || std.Io.UnexpectedError;

pub fn ok(gpa: std.mem.Allocator, stdout: []u8) Error!Output {
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0, .display = null };
}

pub fn okWithDisplay(gpa: std.mem.Allocator, stdout: []u8, display: []u8) Error!Output {
    assert(stdout.len > 0);
    assert(display.len > 0);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0, .display = display };
}

pub fn fail(gpa: std.mem.Allocator, message: []const u8, code: u8) Error!Output {
    assert(code != 0);
    assert(message.len > 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try gpa.dupe(u8, message);
    return .{ .stdout = stdout, .stderr = stderr, .code = code, .display = null };
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
    return .{ .stdout = stdout, .stderr = stderr, .code = code, .display = null };
}
