const std = @import("std");

const common = @import("common.zig");
const edit_file = @import("edit_file.zig");
const fast_search = @import("fast_search.zig");
const parse = @import("parse.zig");
const read_file = @import("read_file.zig");
const write_file = @import("write_file.zig");

pub const Output = common.Output;
pub const Error = common.Error;

/// True when `simple`'s first token names one of our built-in tools, meaning
/// the dispatcher can run it in-process instead of spawning bash. We do not
/// validate flags here — each tool owns its flag surface and returns a
/// non-zero exit on invalid input rather than falling through.
pub fn recognize(simple: parse.Simple) bool {
    if (simple.argv.len == 0) return false;
    const argv0 = simple.argv[0];
    if (std.mem.eql(u8, argv0, read_file.name)) return true;
    if (std.mem.eql(u8, argv0, write_file.name)) return true;
    if (std.mem.eql(u8, argv0, edit_file.name)) return true;
    if (std.mem.eql(u8, argv0, fast_search.name)) return true;
    return false;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    simple: parse.Simple,
    stdin: []const u8,
) Error!Output {
    std.debug.assert(simple.argv.len > 0);
    const argv0 = simple.argv[0];
    const rest = simple.argv[1..];
    if (std.mem.eql(u8, argv0, read_file.name)) return read_file.run(gpa, io, cwd, rest, stdin);
    if (std.mem.eql(u8, argv0, write_file.name)) return write_file.run(gpa, io, cwd, rest, stdin);
    if (std.mem.eql(u8, argv0, edit_file.name)) return edit_file.run(gpa, io, cwd, rest, stdin);
    if (std.mem.eql(u8, argv0, fast_search.name)) return fast_search.run(gpa, io, cwd, rest, stdin);
    unreachable; // recognize() must agree with run().
}

test "recognize matches every registered tool" {
    var argv_read = [_][]const u8{"read-file"};
    var argv_write = [_][]const u8{"write-file"};
    var argv_edit = [_][]const u8{"edit-file"};
    var argv_search = [_][]const u8{"fast-search"};
    var argv_other = [_][]const u8{"cat"};
    try std.testing.expect(recognize(.{ .argv = &argv_read, .redirects = &.{}, .span_start = 0, .span_end = 0 }));
    try std.testing.expect(recognize(.{ .argv = &argv_write, .redirects = &.{}, .span_start = 0, .span_end = 0 }));
    try std.testing.expect(recognize(.{ .argv = &argv_edit, .redirects = &.{}, .span_start = 0, .span_end = 0 }));
    try std.testing.expect(recognize(.{ .argv = &argv_search, .redirects = &.{}, .span_start = 0, .span_end = 0 }));
    try std.testing.expect(!recognize(.{ .argv = &argv_other, .redirects = &.{}, .span_start = 0, .span_end = 0 }));
}
