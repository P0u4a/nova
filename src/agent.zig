const std = @import("std");

const ai = @import("ai.zig");
const tools = @import("tools.zig");

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    client: ai.AIClient,
    messages: std.ArrayList(ai.ChatMessage) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, client: ai.AIClient) Agent {
        return .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
        };
    }

    pub fn addSystem(self: *Agent, content: []const u8) !void {
        try self.appendMessage("system", content);
    }

    pub fn deinit(self: *Agent) void {
        for (self.messages.items) |message| {
            self.gpa.free(message.role);
            self.gpa.free(message.content);
        }
        self.messages.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn addUser(self: *Agent, content: []const u8) !void {
        try self.appendMessage("user", content);
    }

    pub const StreamEvent = union(enum) {
        content_delta: []const u8,
        reasoning_delta: []const u8,
        tool_delta: ToolDelta,
        delta_end,
        tool_finished: ToolFinished,
        tool_batch_finished,
        turn_finished,
        turn_failed: []const u8,

        pub const ToolDelta = struct {
            index: u32,
            name: []const u8,
            arguments: []const u8,
        };

        pub const ToolFinished = struct {
            index: u32,
            command: []const u8,
            body: []const u8,
            failed: bool = false,
        };

        pub fn deinit(self: *StreamEvent, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .content_delta, .reasoning_delta, .turn_failed => |text| gpa.free(text),
                .tool_delta => |tool| {
                    gpa.free(tool.name);
                    gpa.free(tool.arguments);
                },
                .tool_finished => |tool| {
                    gpa.free(tool.command);
                    gpa.free(tool.body);
                },
                .delta_end, .tool_batch_finished, .turn_finished => {},
            }
            self.* = undefined;
        }
    };

    pub const Events = struct {
        context: ?*anyopaque = null,
        post: ?*const fn (?*anyopaque, StreamEvent) anyerror!void = null,
    };

    pub fn turn(self: *Agent, events: Events) !void {
        const tool_call_limit = 8;
        var calls: u32 = 0;
        while (calls < tool_call_limit) : (calls += 1) {
            var stream_context: StreamContext = .{
                .agent = self,
                .events = events,
            };
            defer stream_context.deinit();
            var response = try self.client.completeStream(self.messages.items, .{
                .context = &stream_context,
                .on_content_delta = onContentDelta,
                .on_reasoning_delta = onReasoningDelta,
                .on_tool_delta = onToolDelta,
                .on_delta_end = onDeltaEnd,
            });
            defer response.deinit(self.gpa);

            if (response.content.len > 0) try self.appendMessage("assistant", response.content);
            if (response.tool_calls.items.len == 0) return;
            try self.runTools(response.tool_calls.items, &stream_context, events);
        }
        return error.ToolCallLimit;
    }

    fn runTools(
        self: *Agent,
        tool_calls: []const ai.ToolCall,
        stream_context: *const StreamContext,
        events: Events,
    ) !void {
        for (tool_calls) |tool_call| {
            try self.runToolCall(
                tool_call.index,
                tool_call.name,
                tool_call.arguments,
                stream_context.toolDeltaSeen(tool_call.index),
                events,
            );
        }
        try postEvent(events, .tool_batch_finished);
    }

    fn runToolCall(
        self: *Agent,
        tool_index: u32,
        name: []const u8,
        arguments: []const u8,
        streamed_preview: bool,
        events: Events,
    ) !void {
        if (!streamed_preview) {
            try self.postToolDelta(events, tool_index, name, arguments);
            try postEvent(events, .delta_end);
        }

        var result = try tools.run(self.gpa, self.io, self.cwd, name, arguments);
        defer result.deinit(self.gpa);

        const title = try formatToolTitle(self.gpa, name, arguments);
        defer self.gpa.free(title);

        const failed = result.code != 0;
        const ui_body = try formatUiBody(self.gpa, result.stdout, result.stderr, failed);
        defer self.gpa.free(ui_body);

        const model_message = try std.fmt.allocPrint(
            self.gpa,
            "tool {s}\nexit {d}\nstdout:\n{s}\nstderr:\n{s}",
            .{ title, result.code, result.stdout, result.stderr },
        );
        defer self.gpa.free(model_message);

        try self.postToolFinished(events, tool_index, title, ui_body, failed);
        try self.appendMessage("user", model_message);
    }

    fn formatToolTitle(gpa: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, "bash")) {
            if (parseCommand(gpa, arguments)) |command| return command else |_| {}
        }
        return std.fmt.allocPrint(gpa, "{s} {s}", .{ name, arguments });
    }

    fn formatUiBody(
        gpa: std.mem.Allocator,
        stdout: []const u8,
        stderr: []const u8,
        failed: bool,
    ) ![]u8 {
        if (stdout.len == 0 and stderr.len == 0) {
            return gpa.dupe(u8, if (failed) "an error occurred" else "no output");
        }
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        if (stdout.len > 0) {
            try buffer.appendSlice(gpa, "stdout:\n");
            try buffer.appendSlice(gpa, stdout);
            if (buffer.items[buffer.items.len - 1] != '\n') try buffer.append(gpa, '\n');
        }
        if (stderr.len > 0) {
            try buffer.appendSlice(gpa, "stderr:\n");
            try buffer.appendSlice(gpa, stderr);
        }
        return buffer.toOwnedSlice(gpa);
    }

    const StreamContext = struct {
        agent: *Agent,
        events: Events,
        tool_delta_seen: std.ArrayList(bool) = .empty,

        fn deinit(self: *StreamContext) void {
            self.tool_delta_seen.deinit(self.agent.gpa);
        }

        fn toolDeltaSeen(self: *const StreamContext, tool_index: u32) bool {
            if (tool_index >= self.tool_delta_seen.items.len) return false;
            return self.tool_delta_seen.items[tool_index];
        }

        fn markToolDeltaSeen(self: *StreamContext, tool_index: u32) !void {
            while (self.tool_delta_seen.items.len <= tool_index) {
                try self.tool_delta_seen.append(self.agent.gpa, false);
            }
            self.tool_delta_seen.items[tool_index] = true;
        }
    };

    fn onContentDelta(context: ?*anyopaque, delta: []const u8) !void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context.?));
        const owned = try concrete.agent.gpa.dupe(u8, delta);
        errdefer concrete.agent.gpa.free(owned);
        try postEvent(concrete.events, .{ .content_delta = owned });
    }

    fn onReasoningDelta(context: ?*anyopaque, delta: []const u8) !void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context.?));
        const owned = try concrete.agent.gpa.dupe(u8, delta);
        errdefer concrete.agent.gpa.free(owned);
        try postEvent(concrete.events, .{ .reasoning_delta = owned });
    }

    fn onToolDelta(context: ?*anyopaque, tool_index: u32, name: []const u8, arguments: []const u8) !void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context.?));
        try concrete.markToolDeltaSeen(tool_index);
        try concrete.agent.postToolDelta(concrete.events, tool_index, name, arguments);
    }

    fn onDeltaEnd(context: ?*anyopaque) !void {
        const concrete: *StreamContext = @ptrCast(@alignCast(context.?));
        try postEvent(concrete.events, .delta_end);
    }

    fn postToolDelta(
        self: *Agent,
        events: Events,
        tool_index: u32,
        name: []const u8,
        arguments: []const u8,
    ) !void {
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_arguments = try self.gpa.dupe(u8, arguments);
        errdefer self.gpa.free(owned_arguments);
        try postEvent(events, .{
            .tool_delta = .{
                .index = tool_index,
                .name = owned_name,
                .arguments = owned_arguments,
            },
        });
    }

    fn postToolFinished(
        self: *Agent,
        events: Events,
        tool_index: u32,
        command: []const u8,
        body: []const u8,
        failed: bool,
    ) !void {
        const owned_command = try self.gpa.dupe(u8, command);
        errdefer self.gpa.free(owned_command);
        const owned_body = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(owned_body);
        try postEvent(events, .{
            .tool_finished = .{
                .index = tool_index,
                .command = owned_command,
                .body = owned_body,
                .failed = failed,
            },
        });
    }

    fn postEvent(events: Events, event: StreamEvent) !void {
        if (events.post) |post| {
            try post(events.context, event);
        }
    }

    fn appendMessage(self: *Agent, role: []const u8, content: []const u8) !void {
        const owned_role = try self.gpa.dupe(u8, role);
        errdefer self.gpa.free(owned_role);
        const owned_content = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned_content);
        try self.messages.append(self.gpa, .{
            .role = owned_role,
            .content = owned_content,
        });
    }
};

pub fn parseCommand(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arguments, .{});
    defer parsed.deinit();

    const command = parsed.value.object.get("command") orelse return error.InvalidToolArguments;
    if (command != .string) return error.InvalidToolArguments;
    return try gpa.dupe(u8, command.string);
}

test "parse bash command arguments" {
    const gpa = std.testing.allocator;
    const command = try parseCommand(gpa, "{\"command\":\"zig build test\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("zig build test", command);
}

test "streaming callbacks emit owned events" {
    const gpa = std.testing.allocator;
    const openai = @import("ai/openai.zig");
    var openai_client: openai.Client = undefined;
    try openai_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai = &openai_client });
    defer agent.deinit();

    const Seen = struct {
        events: std.ArrayList(Agent.StreamEvent) = .empty,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.events.items) |*event| {
                event.deinit(allocator);
            }
            self.events.deinit(allocator);
        }

        fn post(context: ?*anyopaque, event: Agent.StreamEvent) !void {
            const seen: *@This() = @ptrCast(@alignCast(context.?));
            try seen.events.append(std.testing.allocator, event);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    var context: Agent.StreamContext = .{
        .agent = &agent,
        .events = .{
            .context = &seen,
            .post = Seen.post,
        },
    };
    defer context.deinit();

    try Agent.onReasoningDelta(&context, "checking");
    try Agent.onContentDelta(&context, "hello");
    try Agent.onToolDelta(&context, 1, "bash", "{\"command\":\"pwd\"}");
    try Agent.onDeltaEnd(&context);

    try std.testing.expectEqual(@as(usize, 4), seen.events.items.len);
    try std.testing.expectEqualStrings("checking", seen.events.items[0].reasoning_delta);
    try std.testing.expectEqualStrings("hello", seen.events.items[1].content_delta);
    try std.testing.expectEqual(@as(u32, 1), seen.events.items[2].tool_delta.index);
    try std.testing.expectEqualStrings("bash", seen.events.items[2].tool_delta.name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", seen.events.items[2].tool_delta.arguments);
    try std.testing.expectEqual(.delta_end, seen.events.items[3]);
    try std.testing.expect(context.toolDeltaSeen(1));
    try std.testing.expect(!context.toolDeltaSeen(0));
}
