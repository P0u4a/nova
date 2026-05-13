const std = @import("std");

const bash = @import("bash.zig");
const common = @import("tools/common.zig");
const edit_file = @import("tools/edit_file.zig");
const read = @import("tools/read.zig");
const search_codebase = @import("tools/search_codebase.zig");
const write_file = @import("tools/write_file.zig");

pub const Output = common.Output;
pub const Error = common.Error;

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    name: []const u8,
    arguments: []const u8,
) Error!bash.Result {
    if (std.mem.eql(u8, name, "bash")) return runBash(gpa, io, cwd, arguments);
    if (std.mem.eql(u8, name, "read")) {
        var output = try read.runTool(gpa, io, cwd, arguments);
        return takeResult(&output);
    }
    if (std.mem.eql(u8, name, "write_file")) {
        var output = try write_file.runTool(gpa, io, cwd, arguments);
        return takeResult(&output);
    }
    if (std.mem.eql(u8, name, "edit_file")) {
        var output = try edit_file.runTool(gpa, io, cwd, arguments);
        return takeResult(&output);
    }
    if (std.mem.eql(u8, name, "search_codebase")) {
        var output = try search_codebase.runTool(gpa, arguments);
        return takeResult(&output);
    }
    return failFmt(gpa, 2, "unknown tool: {s}\n", .{name});
}

fn runBash(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, arguments: []const u8) Error!bash.Result {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch {
        return fail(gpa, "bash: invalid JSON arguments\n", 2);
    };
    defer parsed.deinit();

    const command = parsed.value.object.get("command") orelse return fail(gpa, "bash: missing command\n", 2);
    if (command != .string) return fail(gpa, "bash: command must be a string\n", 2);
    if (command.string.len == 0) return fail(gpa, "bash: command must not be empty\n", 2);
    return bash.run(gpa, io, cwd, command.string) catch |err| return mapExternalError(err);
}

fn fail(gpa: std.mem.Allocator, message: []const u8, code: u8) Error!bash.Result {
    var output = try common.fail(gpa, message, code);
    return takeResult(&output);
}

fn failFmt(gpa: std.mem.Allocator, code: u8, comptime fmt: []const u8, args: anytype) Error!bash.Result {
    var output = try common.failFmt(gpa, code, fmt, args);
    return takeResult(&output);
}

pub fn takeResult(output: *common.Output) bash.Result {
    const result: bash.Result = .{ .stdout = output.stdout, .stderr = output.stderr, .code = output.code };
    output.* = undefined;
    return result;
}

fn mapExternalError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
}

const JsonSchemaProperty = struct {
    type: []const u8,
    description: ?[]const u8 = null,
    minimum: ?i64 = null,
};

const JsonSchemaProperties = struct {
    command: ?JsonSchemaProperty = null,
    path: ?JsonSchemaProperty = null,
    content: ?JsonSchemaProperty = null,
    input: ?JsonSchemaProperty = null,
    query: ?JsonSchemaProperty = null,
};

const JsonSchemaObject = struct {
    type: []const u8 = "object",
    properties: JsonSchemaProperties,
    required: []const []const u8,
};

const FunctionTool = struct {
    name: []const u8,
    description: []const u8,
    parameters: JsonSchemaObject,
};

const ToolDefinition = struct {
    type: []const u8 = "function",
    function: FunctionTool,
};

pub fn buildToolsJson(gpa: std.mem.Allocator) ![]u8 {
    const read_description = try renderToolDescription(gpa, "read");
    defer gpa.free(read_description);
    const edit_description = try renderToolDescription(gpa, "edit_file");
    defer gpa.free(edit_description);
    const write_description = try renderToolDescription(gpa, "write_file");
    defer gpa.free(write_description);

    const required_command = [_][]const u8{"command"};
    const required_path = [_][]const u8{"path"};
    const required_path_content = [_][]const u8{ "path", "content" };
    const required_input = [_][]const u8{"input"};
    const required_query = [_][]const u8{"query"};

    const tool_definitions = [_]ToolDefinition{
        tool(.{
            .name = "bash",
            .description = "Executes bash command in shell session for terminal operations like mkdir, mv, git, builds, and tests. Use the read tool instead of shell commands such as cat, head, tail, less, more, ls, sed -n, or awk NR when inspecting files or directories.",
            .parameters = .{
                .properties = .{ .command = stringProperty("Shell command to execute.") },
                .required = &required_command,
            },
        }),
        tool(.{
            .name = "read",
            .description = read_description,
            .parameters = .{
                .properties = .{
                    .path = stringProperty("Required. File or directory path to read. Append selectors like :50, :50-200, :50+150, :raw, or :conflicts."),
                },
                .required = &required_path,
            },
        }),
        tool(.{
            .name = "write_file",
            .description = write_description,
            .parameters = .{
                .properties = .{
                    .path = stringProperty("Required. File path to create or overwrite, relative to the current working directory unless absolute."),
                    .content = stringProperty("Required. Complete file content to write. Do not put the path here."),
                },
                .required = &required_path_content,
            },
        }),
        tool(.{
            .name = "edit_file",
            .description = edit_description,
            .parameters = .{
                .properties = .{ .input = stringProperty("Hashline patch document only, not an explanation. Must contain at least one @@ PATH header, followed by hashline operations using anchors from read.") },
                .required = &required_input,
            },
        }),
        tool(.{
            .name = "search_codebase",
            .description = "Search the codebase. TODO: not implemented yet.",
            .parameters = .{
                .properties = .{
                    .query = stringProperty("Search query."),
                },
                .required = &required_query,
            },
        }),
    };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(tool_definitions, .{ .emit_null_optional_fields = false }, &aw.writer);
    return aw.toOwnedSlice();
}

fn tool(function: FunctionTool) ToolDefinition {
    return .{ .function = function };
}

fn stringProperty(description: []const u8) JsonSchemaProperty {
    return .{ .type = "string", .description = description };
}

fn integerProperty(description: []const u8, minimum: i64) JsonSchemaProperty {
    return .{ .type = "integer", .description = description, .minimum = minimum };
}

fn renderToolDescription(gpa: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    const prompt = @embedFile("prompts/tools/" ++ name ++ ".md");
    return std.mem.replaceOwned(u8, gpa, prompt, "{{hsep}}", "~");
}

test "write_file schema advertises path and content as required" {
    const json = try buildToolsJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"write_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"path\",\"content\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Always include BOTH `path` and `content`.") != null);
}

test "read schema is named read and advertises path selectors" {
    const json = try buildToolsJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read" ++ "_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, ":50-200") != null);
}

test "tool schema is valid JSON" {
    const json = try buildToolsJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
}

test {
    _ = common;
    _ = edit_file;
    _ = read;
    _ = search_codebase;
    _ = write_file;
    _ = @import("tools/hashline/hash.zig");
    _ = @import("tools/hashline/parse.zig");
    _ = @import("tools/hashline/apply.zig");
}
