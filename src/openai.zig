const std = @import("std");
const ai = @import("ai.zig");

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,

    pub fn completeStream(
        self: *Client,
        messages: []const ai.ChatMessage,
        observer: ai.StreamObserver,
    ) !ai.Response {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "{s}/v1/chat/completions",
            .{std.mem.trimEnd(u8, self.config.base_url, "/")},
        );
        defer self.gpa.free(url);

        const payload = try self.requestPayload(messages, true);
        defer self.gpa.free(payload);

        var client: std.http.Client = .{
            .allocator = self.gpa,
            .io = self.io,
        };
        defer client.deinit();

        const authorization = try std.fmt.allocPrint(
            self.gpa,
            "Bearer {s}",
            .{self.config.api_key},
        );
        defer self.gpa.free(authorization);

        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = "application/json" },
            },
        });
        defer req.deinit();

        try req.sendBodyComplete(payload);
        var redirect_buffer: [8192]u8 = undefined;
        var http_response = try req.receiveHead(&redirect_buffer);
        if (@intFromEnum(http_response.head.status) < 200) return error.HttpStatus;
        if (@intFromEnum(http_response.head.status) >= 300) return error.HttpStatus;

        var transfer_buffer: [4096]u8 = undefined;
        const reader = http_response.reader(&transfer_buffer);
        return try readStream(self.gpa, reader, observer);
    }

    fn requestPayload(self: *Client, messages: []const ai.ChatMessage, stream: bool) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(self.gpa);
        defer writer.deinit();
        const out = &writer.writer;

        try out.writeAll("{\"model\":");
        try std.json.Stringify.value(self.config.model, .{}, out);
        try out.writeAll(",\"messages\":[");
        for (messages, 0..) |message, index| {
            if (index > 0) try out.writeByte(',');
            try out.writeAll("{\"role\":");
            try std.json.Stringify.value(message.role, .{}, out);
            try out.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content, .{}, out);
            try out.writeByte('}');
        }
        if (stream) {
            try out.writeAll("],\"stream\":true");
        } else {
            try out.writeByte(']');
        }
        try out.writeAll(
            \\,"tools":[{"type":"function","function":{"name":"bash","description":"Run a bash command in the current project.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}],"tool_choice":"auto"}
        );
        return try writer.toOwnedSlice();
    }
};

const ToolCallBuilder = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolCallBuilder, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.name.deinit(gpa);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }

    fn toToolCall(self: *ToolCallBuilder, gpa: std.mem.Allocator, index: usize) !ai.ToolCall {
        return .{
            .index = index,
            .id = try self.id.toOwnedSlice(gpa),
            .name = try self.name.toOwnedSlice(gpa),
            .arguments = try self.arguments.toOwnedSlice(gpa),
        };
    }
};

fn readStream(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    observer: ai.StreamObserver,
) !ai.Response {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    while (try reader.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        try parseStreamData(gpa, data, &content, &reasoning, &builders, observer);
    }

    var result: ai.Response = .{
        .content = try content.toOwnedSlice(gpa),
        .reasoning = try reasoning.toOwnedSlice(gpa),
    };
    errdefer result.deinit(gpa);

    for (builders.items, 0..) |*builder, index| {
        if (builder.name.items.len == 0) continue;
        try result.tool_calls.append(gpa, try builder.toToolCall(gpa, index));
    }
    return result;
}

fn parseStreamData(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    observer: ai.StreamObserver,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const choices = parsed.value.object.get("choices") orelse return;
    if (choices.array.items.len == 0) return;
    const delta = choices.array.items[0].object.get("delta") orelse return;

    var changed = false;
    if (jsonString(delta.object.get("content"))) |text| {
        try content.appendSlice(gpa, text);
        changed = true;
        if (observer.on_content_delta) |callback| {
            try callback(observer.context, text);
        }
    }
    const reasoning_text = jsonString(delta.object.get("reasoning")) orelse
        jsonString(delta.object.get("reasoning_content"));
    if (reasoning_text) |text| {
        try reasoning.appendSlice(gpa, text);
        changed = true;
        if (observer.on_reasoning_delta) |callback| {
            try callback(observer.context, text);
        }
    }

    if (delta.object.get("tool_calls")) |tool_calls| {
        for (tool_calls.array.items) |item| {
            if (try parseToolCallDelta(gpa, item, builders, observer)) {
                changed = true;
            }
        }
    }

    if (changed) {
        if (observer.on_delta_end) |callback| {
            try callback(observer.context);
        }
    }
}

fn parseToolCallDelta(
    gpa: std.mem.Allocator,
    item: std.json.Value,
    builders: *std.ArrayList(ToolCallBuilder),
    observer: ai.StreamObserver,
) !bool {
    const index_value = item.object.get("index") orelse return false;
    if (index_value != .integer) return false;
    const index: usize = @intCast(index_value.integer);
    while (builders.items.len <= index) {
        try builders.append(gpa, .{});
    }

    const builder = &builders.items[index];
    var changed = false;
    if (jsonString(item.object.get("id"))) |id| {
        try builder.id.appendSlice(gpa, id);
        changed = true;
    }
    const function = item.object.get("function") orelse return changed;
    if (jsonString(function.object.get("name"))) |name| {
        try builder.name.appendSlice(gpa, name);
        changed = true;
    }
    if (jsonString(function.object.get("arguments"))) |arguments| {
        try builder.arguments.appendSlice(gpa, arguments);
        changed = true;
    }

    if (observer.on_tool_delta) |callback| {
        try callback(observer.context, index, builder.name.items, builder.arguments.items);
    }
    return changed;
}

pub fn parseResponse(gpa: std.mem.Allocator, body: []const u8) !ai.Response {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const choices = parsed.value.object.get("choices") orelse return error.InvalidResponse;
    if (choices.array.items.len == 0) return error.InvalidResponse;
    const message = choices.array.items[0].object.get("message") orelse return error.InvalidResponse;
    const reasoning = jsonString(message.object.get("reasoning")) orelse
        jsonString(message.object.get("reasoning_content")) orelse "";

    var response: ai.Response = .{
        .content = try gpa.dupe(u8, jsonString(message.object.get("content")) orelse ""),
        .reasoning = try gpa.dupe(u8, reasoning),
    };
    errdefer response.deinit(gpa);

    if (message.object.get("tool_calls")) |tool_calls| {
        for (tool_calls.array.items) |item| {
            const call = item.object;
            const function = call.get("function") orelse continue;
            try response.tool_calls.append(gpa, .{
                .index = response.tool_calls.items.len,
                .id = try gpa.dupe(u8, jsonString(call.get("id")) orelse ""),
                .name = try gpa.dupe(u8, jsonString(function.object.get("name")) orelse ""),
                .arguments = try gpa.dupe(u8, jsonString(function.object.get("arguments")) orelse "{}"),
            });
        }
    }

    return response;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const concrete = value orelse return null;
    return switch (concrete) {
        .string => |string| string,
        .null => null,
        else => null,
    };
}

test "parse response content and tool calls" {
    const gpa = std.testing.allocator;
    var response = try parseResponse(gpa,
        \\{"choices":[{"message":{"content":"done","tool_calls":[{"id":"1","function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}}]}}]}
    );
    defer response.deinit(gpa);

    try std.testing.expectEqualStrings("done", response.content);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.items.len);
    try std.testing.expectEqualStrings("bash", response.tool_calls.items[0].name);
}

test "parse streaming tool deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
        index: usize = 0,

        fn onToolDelta(context: ?*anyopaque, index: usize, name: []const u8, arguments: []const u8) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            seen.index = index;
            seen.name = name;
            seen.arguments = arguments;
        }
    };
    var seen: Seen = .{};

    try parseStreamData(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"zig"}}]}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_tool_delta = Seen.onToolDelta,
    });
    try parseStreamData(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" build\"}"}}]}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_tool_delta = Seen.onToolDelta,
    });

    try std.testing.expectEqualStrings("bash", seen.name);
    try std.testing.expectEqualStrings("{\"command\":\"zig build\"}", seen.arguments);
    try std.testing.expectEqual(@as(usize, 0), seen.index);
}

test "parse streaming tool deltas batches render notification per event" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        tool_delta_count: u32 = 0,
        render_count: u32 = 0,

        fn onToolDelta(context: ?*anyopaque, _: usize, _: []const u8, _: []const u8) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            seen.tool_delta_count += 1;
        }

        fn onDeltaEnd(context: ?*anyopaque) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            seen.render_count += 1;
        }
    };
    var seen: Seen = .{};

    try parseStreamData(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}},{"index":1,"id":"call_2","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_tool_delta = Seen.onToolDelta,
        .on_delta_end = Seen.onDeltaEnd,
    });

    try std.testing.expectEqual(@as(u32, 2), seen.tool_delta_count);
    try std.testing.expectEqual(@as(u32, 1), seen.render_count);
}

test "parse streaming reasoning deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        gpa: std.mem.Allocator,
        reasoning: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.reasoning.deinit(self.gpa);
        }

        fn onReasoningDelta(context: ?*anyopaque, delta: []const u8) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            try seen.reasoning.appendSlice(seen.gpa, delta);
        }
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();

    try parseStreamData(gpa,
        \\{"choices":[{"delta":{"reasoning_content":"checking output"}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_reasoning_delta = Seen.onReasoningDelta,
    });

    try std.testing.expectEqualStrings("checking output", seen.reasoning.items);
    try std.testing.expectEqualStrings("checking output", reasoning.items);
}

test "parse streaming content deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var builders: std.ArrayList(ToolCallBuilder) = .empty;
    defer {
        for (builders.items) |*builder| {
            builder.deinit(gpa);
        }
        builders.deinit(gpa);
    }

    const Seen = struct {
        gpa: std.mem.Allocator,
        content: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.content.deinit(self.gpa);
        }

        fn onContentDelta(context: ?*anyopaque, delta: []const u8) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            try seen.content.appendSlice(seen.gpa, delta);
        }
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();

    try parseStreamData(gpa,
        \\{"choices":[{"delta":{"content":"hel"}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_content_delta = Seen.onContentDelta,
    });
    try parseStreamData(gpa,
        \\{"choices":[{"delta":{"content":"lo"}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_content_delta = Seen.onContentDelta,
    });

    try std.testing.expectEqualStrings("hello", seen.content.items);
    try std.testing.expectEqualStrings("hello", content.items);
}
