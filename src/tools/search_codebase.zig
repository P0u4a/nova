const std = @import("std");
const common = @import("common.zig");

pub fn runTool(gpa: std.mem.Allocator, arguments: []const u8) common.Error!common.Output {
    _ = arguments;
    return common.fail(gpa, "search_codebase: not implemented yet\n", 2);
}

test "search_codebase is a todo" {
    var output = try runTool(std.testing.allocator, "{\"query\":\"foo\"}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.code);
}
