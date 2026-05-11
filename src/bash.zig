const std = @import("std");

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, command: []const u8) !Result {
    const child_result = try std.process.run(gpa, io, .{
        .argv = &.{ "bash", "-lc", command },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    errdefer gpa.free(child_result.stdout);
    errdefer gpa.free(child_result.stderr);

    const code: u8 = switch (child_result.term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => 255,
    };
    return .{
        .stdout = child_result.stdout,
        .stderr = child_result.stderr,
        .code = code,
    };
}

test "bash captures stdout and exit code" {
    const gpa = std.testing.allocator;
    var result = try run(gpa, std.testing.io, "printf hello");
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.code);
}
