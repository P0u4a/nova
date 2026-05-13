const std = @import("std");
const ai = @import("../ai.zig");

const Scanner = std.json.Scanner;

const redirect_buffer_bytes: u32 = 8192;
const transfer_buffer_bytes: u32 = 4096;
const body_buffer_bytes: u32 = 4096;
const tool_call_count_max: u32 = 16;
const stream_chunk_count_max: u32 = 100_000;
const stream_bytes_max: u32 = 8 * 1024 * 1024;

/// OpenAI-compatible AI client using the Completions API.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: []u8,
    http_client: std.http.Client,

    pub fn init(
        target: *Client,
        gpa: std.mem.Allocator,
        io: std.Io,
        config: ai.Config,
    ) !void {
        std.debug.assert(config.base_url.len > 0);
        std.debug.assert(config.model.len > 0);

        const url = try std.fmt.allocPrint(
            gpa,
            "{s}/v1/chat/completions",
            .{std.mem.trimEnd(u8, config.base_url, "/")},
        );
        errdefer gpa.free(url);

        const authorization = try std.fmt.allocPrint(
            gpa,
            "Bearer {s}",
            .{config.api_key},
        );
        errdefer gpa.free(authorization);

        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .url = url,
            .authorization = authorization,
            .http_client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.gpa.free(self.authorization);
        self.gpa.free(self.url);
        self.* = undefined;
    }

    pub fn completeStream(
        self: *Client,
        messages: []const ai.ChatMessage,
        observer: ai.StreamObserver,
    ) !ai.Response {
        std.debug.assert(self.url.len > 0);
        std.debug.assert(self.authorization.len > 0);

        var req = try self.http_client.request(.POST, try std.Uri.parse(self.url), .{
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .content_type = .{ .override = "application/json" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .chunked;
        var body_buffer: [body_buffer_bytes]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&body_buffer);
        try writeRequestPayload(&body_writer.writer, self.config.model, messages, self.config.tools_json);
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
        var http_response = try req.receiveHead(&redirect_buffer);
        const status_code: u16 = @intFromEnum(http_response.head.status);
        if (status_code >= 500) return error.HttpServerError;
        if (status_code >= 400) return error.HttpClientError;
        if (status_code < 200 or status_code >= 300) return error.HttpUnexpectedStatus;

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const reader = http_response.reader(&transfer_buffer);
        return try readStream(self.gpa, reader, observer);
    }
};

fn writeRequestPayload(
    out: *std.Io.Writer,
    model: []const u8,
    messages: []const ai.ChatMessage,
    tools_json: []const u8,
) !void {
    std.debug.assert(model.len > 0);
    std.debug.assert(tools_json.len > 0);

    try out.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, out);
    try out.writeAll(",\"messages\":[");
    for (messages, 0..) |message, index| {
        if (index > 0) try out.writeByte(',');
        try out.writeAll("{\"role\":");
        try std.json.Stringify.value(message.role, .{}, out);
        try out.writeAll(",\"content\":");
        try std.json.Stringify.value(message.content, .{}, out);
        try out.writeByte('}');
    }
    try out.writeAll("],\"stream\":true,\"tools\":");
    try out.writeAll(tools_json);
    try out.writeAll(",\"tool_choice\":\"auto\"}");
}

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

    fn toToolCall(self: *ToolCallBuilder, gpa: std.mem.Allocator, index: u32) !ai.ToolCall {
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

    var chunk_count: u32 = 0;
    var bytes_read: u32 = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        chunk_count += 1;
        bytes_read +|= @intCast(line.len);
        if (chunk_count > stream_chunk_count_max) return error.StreamTooManyChunks;
        if (bytes_read > stream_bytes_max) return error.StreamTooLarge;
        const trimmed = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        try processStreamChunk(gpa, data, &content, &reasoning, &builders, observer);
    }

    var result: ai.Response = .{
        .content = try content.toOwnedSlice(gpa),
        .reasoning = try reasoning.toOwnedSlice(gpa),
    };
    errdefer result.deinit(gpa);

    for (builders.items, 0..) |*builder, i| {
        if (builder.name.items.len == 0) continue;
        const index: u32 = @intCast(i);
        try result.tool_calls.append(gpa, try builder.toToolCall(gpa, index));
    }
    return result;
}

const ChunkChange = struct {
    content_start: ?u32 = null,
    reasoning_start: ?u32 = null,
    tool_call_indexes: [tool_call_count_max]u32 = @splat(0),
    tool_call_count: u32 = 0,

    fn empty(self: *const ChunkChange) bool {
        if (self.content_start != null) return false;
        if (self.reasoning_start != null) return false;
        if (self.tool_call_count > 0) return false;
        return true;
    }

    fn recordToolCall(self: *ChunkChange, index: u32) void {
        for (self.tool_call_indexes[0..self.tool_call_count]) |existing| {
            if (existing == index) return;
        }
        std.debug.assert(self.tool_call_count < tool_call_count_max);
        self.tool_call_indexes[self.tool_call_count] = index;
        self.tool_call_count += 1;
    }
};

fn applyChunkCallbacks(
    change: ChunkChange,
    content: []const u8,
    reasoning: []const u8,
    builders: []const ToolCallBuilder,
    observer: ai.StreamObserver,
) !void {
    if (change.content_start) |start| {
        if (observer.on_content_delta) |callback| {
            try callback(observer.context, content[start..]);
        }
    }
    if (change.reasoning_start) |start| {
        if (observer.on_reasoning_delta) |callback| {
            try callback(observer.context, reasoning[start..]);
        }
    }
    for (change.tool_call_indexes[0..change.tool_call_count]) |idx| {
        const builder = builders[idx];
        if (observer.on_tool_delta) |callback| {
            try callback(observer.context, idx, builder.name.items, builder.arguments.items);
        }
    }
    if (change.empty()) return;
    if (observer.on_delta_end) |callback| try callback(observer.context);
}

fn processStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    observer: ai.StreamObserver,
) !void {
    const change = try parseStreamChunk(gpa, data, content, reasoning, builders);
    try applyChunkCallbacks(change, content.items, reasoning.items, builders.items, observer);
}

fn parseStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
) !ChunkChange {
    std.debug.assert(data.len > 0);

    var scanner = Scanner.initCompleteInput(gpa, data);
    defer scanner.deinit();

    var change: ChunkChange = .{};
    try expectObjectBegin(&scanner);
    while (try nextObjectKey(&scanner)) |key| {
        if (std.mem.eql(u8, key, "choices")) {
            try parseChoicesArray(gpa, &scanner, content, reasoning, builders, &change);
        } else {
            try scanner.skipValue();
        }
    }
    return change;
}

fn parseChoicesArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    var saw_first = false;
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        if (saw_first) {
            try scanner.skipValue();
            continue;
        }
        try expectObjectBegin(scanner);
        try parseChoiceObject(gpa, scanner, content, reasoning, builders, change);
        saw_first = true;
    }
}

fn parseChoiceObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "delta")) {
            try parseDeltaObject(gpa, scanner, content, reasoning, builders, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseDeltaObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "content")) {
            const before: u32 = @intCast(content.items.len);
            try appendStringValue(scanner, gpa, content);
            if (content.items.len > before) change.content_start = before;
        } else if (std.mem.eql(u8, key, "reasoning") or std.mem.eql(u8, key, "reasoning_content")) {
            const before: u32 = @intCast(reasoning.items.len);
            try appendStringValue(scanner, gpa, reasoning);
            if (reasoning.items.len > before) change.reasoning_start = before;
        } else if (std.mem.eql(u8, key, "tool_calls")) {
            try parseToolCallsArray(gpa, scanner, builders, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseToolCallsArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        try expectObjectBegin(scanner);
        try parseToolCallObject(gpa, scanner, builders, change);
    }
}

fn parseToolCallObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    builders: *std.ArrayList(ToolCallBuilder),
    change: *ChunkChange,
) !void {
    var pending: ToolCallBuilder = .{};
    defer pending.deinit(gpa);
    var has_pending_id = false;
    var has_pending_name = false;
    var has_pending_arguments = false;
    var resolved_index: ?u32 = null;

    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "index")) {
            const index = try nextInteger(scanner);
            if (index < 0) return error.InvalidToolCallIndex;
            if (index >= tool_call_count_max) return error.TooManyToolCalls;
            resolved_index = @intCast(index);
        } else if (std.mem.eql(u8, key, "id")) {
            try appendStringValue(scanner, gpa, &pending.id);
            has_pending_id = true;
        } else if (std.mem.eql(u8, key, "function")) {
            try parseToolCallFunction(gpa, scanner, &pending, &has_pending_name, &has_pending_arguments);
        } else {
            try scanner.skipValue();
        }
    }

    const idx = resolved_index orelse return;
    while (builders.items.len <= idx) try builders.append(gpa, .{});
    const target = &builders.items[@as(usize, idx)];

    if (has_pending_id) try target.id.appendSlice(gpa, pending.id.items);
    if (has_pending_name) try target.name.appendSlice(gpa, pending.name.items);
    if (has_pending_arguments) try target.arguments.appendSlice(gpa, pending.arguments.items);
    change.recordToolCall(idx);
}

fn parseToolCallFunction(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    pending: *ToolCallBuilder,
    has_pending_name: *bool,
    has_pending_arguments: *bool,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "name")) {
            try appendStringValue(scanner, gpa, &pending.name);
            has_pending_name.* = true;
        } else if (std.mem.eql(u8, key, "arguments")) {
            try appendStringValue(scanner, gpa, &pending.arguments);
            has_pending_arguments.* = true;
        } else {
            try scanner.skipValue();
        }
    }
}

fn expectObjectBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .object_begin) return error.UnexpectedToken;
}

fn expectArrayBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .array_begin) return error.UnexpectedToken;
}

fn nextObjectKey(scanner: *Scanner) !?[]const u8 {
    const token = try scanner.next();
    return switch (token) {
        .object_end => null,
        .string => |s| s,
        else => error.UnexpectedToken,
    };
}

fn nextInteger(scanner: *Scanner) !i64 {
    const token = try scanner.next();
    const text = switch (token) {
        .number => |s| s,
        else => return error.UnexpectedToken,
    };
    return try std.fmt.parseInt(i64, text, 10);
}

fn appendStringValue(scanner: *Scanner, gpa: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .string => |s| {
                try list.appendSlice(gpa, s);
                return;
            },
            .partial_string => |s| try list.appendSlice(gpa, s),
            .partial_string_escaped_1 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_2 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_3 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_4 => |bytes| try list.appendSlice(gpa, &bytes),
            else => return error.UnexpectedToken,
        }
    }
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
        index: u32 = 0,

        fn onToolDelta(context: ?*anyopaque, index: u32, name: []const u8, arguments: []const u8) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            seen.index = index;
            seen.name = name;
            seen.arguments = arguments;
        }
    };
    var seen: Seen = .{};

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"zig"}}]}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_tool_delta = Seen.onToolDelta,
    });
    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" build\"}"}}]}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_tool_delta = Seen.onToolDelta,
    });

    try std.testing.expectEqualStrings("bash", seen.name);
    try std.testing.expectEqualStrings("{\"command\":\"zig build\"}", seen.arguments);
    try std.testing.expectEqual(@as(u32, 0), seen.index);
}

test "parse streaming tool deltas tolerate key reorder" {
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

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"function":{"name":"bash","arguments":"{}"},"id":"call_1","index":0}]}}]}
    , &content, &reasoning, &builders, .{});

    try std.testing.expectEqual(@as(usize, 1), builders.items.len);
    try std.testing.expectEqualStrings("call_1", builders.items[0].id.items);
    try std.testing.expectEqualStrings("bash", builders.items[0].name.items);
    try std.testing.expectEqualStrings("{}", builders.items[0].arguments.items);
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

        fn onToolDelta(context: ?*anyopaque, _: u32, _: []const u8, _: []const u8) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            seen.tool_delta_count += 1;
        }

        fn onDeltaEnd(context: ?*anyopaque) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            seen.render_count += 1;
        }
    };
    var seen: Seen = .{};

    try processStreamChunk(gpa,
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

    try processStreamChunk(gpa,
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

    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hel"}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_content_delta = Seen.onContentDelta,
    });
    try processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"lo"}}]}
    , &content, &reasoning, &builders, .{
        .context = &seen,
        .on_content_delta = Seen.onContentDelta,
    });

    try std.testing.expectEqualStrings("hello", seen.content.items);
    try std.testing.expectEqualStrings("hello", content.items);
}
