const std = @import("std");

const bash = @import("bash.zig");
const common = @import("tools/common.zig");
const edit_file = @import("tools/edit_file.zig");
const read_file = @import("tools/read_file.zig");
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
    if (std.mem.eql(u8, name, "read_file")) {
        var output = try read_file.runTool(gpa, io, cwd, arguments);
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
    offset: ?JsonSchemaProperty = null,
    limit: ?JsonSchemaProperty = null,
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
    const edit_description = try renderToolDescription(gpa, "edit_file");
    defer gpa.free(edit_description);

    const required_command = [_][]const u8{"command"};
    const required_path = [_][]const u8{"path"};
    const required_path_content = [_][]const u8{ "path", "content" };
    const required_input = [_][]const u8{"input"};
    const required_query = [_][]const u8{"query"};

    const tool_definitions = [_]ToolDefinition{
        tool(.{
            .name = "bash",
            .description = "Executes bash command in shell session for terminal operations like ls, cd, mkdir, mv, git and more.",
            .parameters = .{
                .properties = .{ .command = stringProperty("Shell command to execute.") },
                .required = &required_command,
            },
        }),
        tool(.{
            .name = "read_file",
            .description = "Read a file. Output lines are formatted as LINE+HASH|TEXT, for example 42ab|const x = 1;. Use the full LINE+HASH anchor exactly as shown when calling edit_file.",
            .parameters = .{
                .properties = .{
                    .path = stringProperty("File path to read, relative to the current working directory unless absolute."),
                    .offset = integerProperty("Optional 1-indexed first line to read. Use the next offset shown in truncation footers to continue.", 1),
                    .limit = integerProperty("Optional maximum number of lines to return.", 0),
                },
                .required = &required_path,
            },
        }),
        tool(.{
            .name = "write_file",
            .description = "Write complete file content, creating parent directories as needed. Use for new files or full rewrites. Use edit_file for targeted edits to existing files.",
            .parameters = .{
                .properties = .{
                    .path = stringProperty("File path to write, relative to the current working directory unless absolute."),
                    .content = stringProperty("Complete file content to write."),
                },
                .required = &required_path_content,
            },
        }),
        tool(.{
            .name = "edit_file",
            .description = edit_description,
            .parameters = .{
                .properties = .{ .input = stringProperty("Hashline patch document only, not an explanation. Must contain at least one @@ PATH header, followed by hashline operations using anchors from read_file.") },
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
    _ = read_file;
    _ = search_codebase;
    _ = write_file;
    _ = @import("tools/hashline/hash.zig");
    _ = @import("tools/hashline/parse.zig");
    _ = @import("tools/hashline/apply.zig");
}
