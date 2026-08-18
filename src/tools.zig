const std = @import("std");

const bash_tool = @import("tools/bash.zig");
const common = @import("tools/common.zig");
const edit_text = @import("tools/edit_text.zig");
const edit_tool = @import("tools/edit.zig");
const write_tool = @import("tools/write.zig");
const search_tools = @import("tools/search_tools.zig");

const assert = std.debug.assert;

pub const Output = common.Output;
pub const DisplayKind = common.DisplayKind;
pub const Error = common.Error;
pub const Tool = common.Tool;
pub const Schema = common.Schema;
pub const ToolDisplay = common.ToolDisplay;

pub const registry: []const Tool = &.{
    bash_tool.tool,
    edit_tool.tool,
    write_tool.tool,
    search_tools.find_tool,
    search_tools.grep_tool,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    name: []const u8,
    arguments: []const u8,
) Error!Output {
    const tool = lookup(name) orelse return failFmt(gpa, 2, "unknown tool: {s}\n", .{name});
    return tool.run(gpa, io, cwd, arguments);
}

/// Locate a tool in the registry by name. Returns null when no tool with
/// that name exists. Linear scan over a fixed-size slice — fine for the
/// handful of tools Nova exposes.
pub fn lookup(name: []const u8) ?Tool {
    assert(name.len > 0);
    for (registry) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn failFmt(gpa: std.mem.Allocator, code: u8, comptime fmt: []const u8, args: anytype) Error!Output {
    return common.failFmt(gpa, code, fmt, args);
}

test "registry contains every tool exactly once" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (registry) |tool| {
        const gop = try seen.getOrPut(std.testing.allocator, tool.name);
        try std.testing.expect(!gop.found_existing);
    }
}

test "every registered tool declares a name, description, and schema" {
    for (registry) |tool| {
        try std.testing.expect(tool.name.len > 0);
        try std.testing.expect(tool.description.len > 0);
        for (tool.schema.properties) |property| {
            try std.testing.expect(property.name.len > 0);
            try std.testing.expect(property.description.len > 0);
        }
    }
}

test "every registered tool serializes to valid JSON Schema" {
    const gpa = std.testing.allocator;
    for (registry) |tool| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try tool.schema.writeJson(&out.writer);
        const json = out.written();

        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const kind = parsed.value.object.get("type") orelse return error.TestFailed;
        try std.testing.expectEqualStrings("object", kind.string);
        try std.testing.expect(parsed.value.object.get("properties") != null);
        try std.testing.expect(parsed.value.object.get("required") != null);
    }
}

test "lookup finds a registered tool" {
    const tool = lookup("bash") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("bash", tool.name);
}

test "lookup returns null for unknown tool" {
    try std.testing.expect(lookup("does_not_exist") == null);
}

test {
    _ = bash_tool;
    _ = edit_text;
    _ = edit_tool;
    _ = write_tool;
    _ = search_tools;
    _ = common;
}
