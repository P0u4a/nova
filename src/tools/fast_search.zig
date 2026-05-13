const std = @import("std");
const common = @import("common.zig");

pub const name = "fast-search";

pub const help_text =
    \\Usage: fast-search [--help]
    \\
    \\Reserved for a future code-search tool. For now, use grep or
    \\ripgrep through bash.
    \\
    \\Options:
    \\  --help       show this message
;

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    stdin: []const u8,
) common.Error!common.Output {
    _ = io;
    _ = cwd;
    _ = stdin;
    if (common.wantsHelp(argv)) return common.helpOutput(gpa, help_text);
    return common.fail(gpa, "fast-search: not implemented yet\n", 2);
}
