const std = @import("std");
const builtin = @import("builtin");

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
        .argv = &.{ bashPath(io), "-lc", command },
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

// On Windows, `bash` on PATH may resolve to the WSL bash bridge in
// system32, which talks to a Windows service that intermittently exhausts
// socket buffers (WSAENOBUFS / Bash/Service/0x80072747). Prefer git bash when
// available.
const windows_bash_candidates = [_][]const u8{
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
};

// TODO: Persist this
var bash_path_value: ?[]const u8 = null;

fn bashPath(io: std.Io) []const u8 {
    if (bash_path_value) |p| return p;
    const resolved = resolveBashPath(io);
    bash_path_value = resolved;
    return resolved;
}

fn resolveBashPath(io: std.Io) []const u8 {
    if (builtin.os.tag != .windows) return "bash";
    for (windows_bash_candidates) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return path;
    }
    return "bash";
}

test "bash captures stdout and exit code" {
    const gpa = std.testing.allocator;
    var result = try run(gpa, std.testing.io, "printf hello");
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.code);
}
