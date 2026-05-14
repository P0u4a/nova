const std = @import("std");

const ai = @import("ai.zig");
const hashline = @import("tools/hashline/hash.zig");
const tools = @import("tools.zig");

const assert = std.debug.assert;

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    client: ai.AIClient,
    messages: std.ArrayList(ai.ChatMessage) = .empty,
    /// Monotonic counter for fallback tool_call ids when the inference
    /// server omits them. The canonical OpenAI protocol requires ids that
    /// link assistant tool_calls to their `tool` result messages.
    tool_call_seq: u64 = 0,

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
            if (message.tool_call_id) |id| self.gpa.free(id);
            if (message.tool_calls.len > 0) {
                for (message.tool_calls) |tool_call| {
                    var owned = tool_call;
                    owned.deinit(self.gpa);
                }
                self.gpa.free(message.tool_calls);
            }
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
            /// True when the thread message should be rendered with its body
            /// visible immediately, instead of collapsed behind its title.
            /// Set by `tools.defaultExpanded(name)` in `runToolCall`.
            expanded: bool = false,
            /// How the TUI should colour the body. Set by `tools.renderMode`.
            render: tools.Render = .plain,
            /// Owned stderr text rendered in red beneath the body, or null
            /// when the tool produced no stderr output.
            stderr_body: ?[]const u8 = null,
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
                    if (tool.stderr_body) |stderr| gpa.free(stderr);
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

            var resolved_ids: std.ArrayList([]u8) = .empty;
            defer {
                for (resolved_ids.items) |id| self.gpa.free(id);
                resolved_ids.deinit(self.gpa);
            }
            try self.resolveToolCallIds(&resolved_ids, response.tool_calls.items);

            if (response.tool_calls.items.len > 0) {
                try self.appendAssistantTurn(response.content, response.tool_calls.items, resolved_ids.items);
            } else if (response.content.len > 0) {
                try self.appendMessage("assistant", response.content);
            }

            if (response.tool_calls.items.len == 0) return;
            try self.runTools(response.tool_calls.items, resolved_ids.items, &stream_context, events);
        }
        return error.ToolCallLimit;
    }

    /// Fill `out` with one owned id per tool_call. When the inference server
    /// returned an id we dupe it; when it didn't we mint a fallback so the
    /// assistant message and the tool result message agree on the linkage.
    fn resolveToolCallIds(
        self: *Agent,
        out: *std.ArrayList([]u8),
        tool_calls: []const ai.ToolCall,
    ) !void {
        for (tool_calls) |tool_call| {
            const owned = if (tool_call.id.len > 0)
                try self.gpa.dupe(u8, tool_call.id)
            else
                try self.nextToolCallId();
            try out.append(self.gpa, owned);
        }
    }

    fn nextToolCallId(self: *Agent) ![]u8 {
        const seq = self.tool_call_seq;
        self.tool_call_seq += 1;
        return std.fmt.allocPrint(self.gpa, "call_{d}", .{seq});
    }

    fn runTools(
        self: *Agent,
        tool_calls: []const ai.ToolCall,
        tool_call_ids: []const []u8,
        stream_context: *const StreamContext,
        events: Events,
    ) !void {
        assert(tool_calls.len == tool_call_ids.len);
        for (tool_calls, tool_call_ids) |tool_call, tool_call_id| {
            try self.runToolCall(
                tool_call.index,
                tool_call_id,
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
        tool_call_id: []const u8,
        name: []const u8,
        arguments: []const u8,
        streamed_preview: bool,
        events: Events,
    ) !void {
        assert(tool_call_id.len > 0);
        if (!streamed_preview) {
            try self.postToolDelta(events, tool_index, name, arguments);
            try postEvent(events, .delta_end);
        }

        var result = try tools.run(self.gpa, self.io, self.cwd, name, arguments);
        defer result.deinit(self.gpa);

        const title = try formatToolTitle(self.gpa, name, arguments);
        defer self.gpa.free(title);

        const failed = result.code != 0;
        const expanded = tools.defaultExpanded(name);
        const render = tools.renderMode(name);

        var ui = try resolveUiParts(self.gpa, result);
        defer ui.deinit(self.gpa);

        const tool_result_content = try formatToolResultContent(self.gpa, result);
        defer self.gpa.free(tool_result_content);

        try self.postToolFinished(events, tool_index, title, ui.body, ui.stderr, failed, expanded, render);
        try self.appendToolResult(tool_call_id, tool_result_content);
    }

    const UiParts = struct {
        body: []u8,
        stderr: ?[]u8,

        fn deinit(self: *UiParts, gpa: std.mem.Allocator) void {
            gpa.free(self.body);
            if (self.stderr) |stderr| gpa.free(stderr);
            self.* = undefined;
        }
    };

    /// The string we send back to the model as a tool result. Rule:
    /// stdout if non-empty, else stderr if non-empty, else the literal
    /// "empty". When both are non-empty (typical for bash commands that
    /// write to both streams) we concatenate them so we don't drop signal.
    fn formatToolResultContent(gpa: std.mem.Allocator, result: tools.Result) ![]u8 {
        if (result.stdout.len > 0 and result.stderr.len > 0) {
            return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ result.stdout, result.stderr });
        }
        if (result.stdout.len > 0) return gpa.dupe(u8, result.stdout);
        if (result.stderr.len > 0) return gpa.dupe(u8, result.stderr);
        return gpa.dupe(u8, "empty");
    }

    /// Picks the body and stderr shown in the TUI. The body carries the
    /// tool's "main" output (display body when the tool emitted one, else
    /// the stdout text), styled per the tool's render mode. Stderr is held
    /// separately so the TUI can paint it red beneath the body.
    fn resolveUiParts(gpa: std.mem.Allocator, result: tools.Result) !UiParts {
        const body = try resolveUiBodyText(gpa, result);
        errdefer gpa.free(body);
        const stderr = try resolveUiStderr(gpa, result.stderr);
        return .{ .body = body, .stderr = stderr };
    }

    fn resolveUiBodyText(gpa: std.mem.Allocator, result: tools.Result) ![]u8 {
        if (result.display) |display| {
            assert(display.len > 0);
            return gpa.dupe(u8, display);
        }
        if (result.stdout.len == 0) {
            if (result.stderr.len > 0) return gpa.alloc(u8, 0);
            return gpa.dupe(u8, "no output");
        }
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(gpa);
        try hashline.appendStripped(gpa, &buffer, result.stdout);
        return buffer.toOwnedSlice(gpa);
    }

    fn resolveUiStderr(gpa: std.mem.Allocator, stderr: []const u8) !?[]u8 {
        if (stderr.len == 0) return null;
        return try gpa.dupe(u8, stderr);
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
        stderr_body: ?[]const u8,
        failed: bool,
        expanded: bool,
        render: tools.Render,
    ) !void {
        const owned_command = try self.gpa.dupe(u8, command);
        errdefer self.gpa.free(owned_command);
        const owned_body = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(owned_body);
        const owned_stderr: ?[]u8 = if (stderr_body) |stderr|
            try self.gpa.dupe(u8, stderr)
        else
            null;
        errdefer if (owned_stderr) |stderr| self.gpa.free(stderr);
        try postEvent(events, .{
            .tool_finished = .{
                .index = tool_index,
                .command = owned_command,
                .body = owned_body,
                .failed = failed,
                .expanded = expanded,
                .render = render,
                .stderr_body = owned_stderr,
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

    /// Append an assistant message that emitted at least one tool_call.
    /// Per OpenAI's protocol the assistant message must carry the tool_calls
    /// it produced so the subsequent `tool` messages can reference them by id.
    fn appendAssistantTurn(
        self: *Agent,
        content: []const u8,
        tool_calls: []const ai.ToolCall,
        resolved_ids: []const []u8,
    ) !void {
        assert(tool_calls.len > 0);
        assert(tool_calls.len == resolved_ids.len);

        const owned_role = try self.gpa.dupe(u8, "assistant");
        errdefer self.gpa.free(owned_role);
        const owned_content = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned_content);

        const stored = try self.gpa.alloc(ai.StoredToolCall, tool_calls.len);
        var initialized: usize = 0;
        errdefer {
            for (stored[0..initialized]) |tool_call| {
                var owned = tool_call;
                owned.deinit(self.gpa);
            }
            self.gpa.free(stored);
        }

        for (tool_calls, resolved_ids) |tool_call, id| {
            const owned_id = try self.gpa.dupe(u8, id);
            errdefer self.gpa.free(owned_id);
            const owned_name = try self.gpa.dupe(u8, tool_call.name);
            errdefer self.gpa.free(owned_name);
            const owned_args = try self.gpa.dupe(u8, tool_call.arguments);
            stored[initialized] = .{
                .id = owned_id,
                .name = owned_name,
                .arguments = owned_args,
            };
            initialized += 1;
        }

        try self.messages.append(self.gpa, .{
            .role = owned_role,
            .content = owned_content,
            .tool_calls = stored,
        });
    }

    /// Append a `tool` role message carrying the result of one tool_call.
    fn appendToolResult(
        self: *Agent,
        tool_call_id: []const u8,
        content: []const u8,
    ) !void {
        assert(tool_call_id.len > 0);
        const owned_role = try self.gpa.dupe(u8, "tool");
        errdefer self.gpa.free(owned_role);
        const owned_content = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned_content);
        const owned_id = try self.gpa.dupe(u8, tool_call_id);
        errdefer self.gpa.free(owned_id);
        try self.messages.append(self.gpa, .{
            .role = owned_role,
            .content = owned_content,
            .tool_call_id = owned_id,
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

/// Render a friendly title for a tool call. For `bash` we surface the command
/// itself; for `write_file` and `edit_file` we surface the affected path(s)
/// rather than the full JSON, since the JSON body for those tools is large
/// and uninformative as a label. Falls back to bare `<name>` while the model
/// is still streaming an incomplete argument JSON.
pub fn formatToolTitle(gpa: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]u8 {
    if (std.mem.eql(u8, name, "bash")) {
        if (parseCommand(gpa, arguments)) |command| return command else |_| {}
        return gpa.dupe(u8, "bash");
    }
    if (std.mem.eql(u8, name, "write_file")) {
        if (formatWriteFileTitle(gpa, arguments)) |title| return title else |_| {}
        return gpa.dupe(u8, "write_file");
    }
    if (std.mem.eql(u8, name, "edit_file")) {
        if (formatEditFileTitle(gpa, arguments)) |title| return title else |_| {}
        return gpa.dupe(u8, "edit_file");
    }
    return std.fmt.allocPrint(gpa, "{s} {s}", .{ name, arguments });
}

fn formatWriteFileTitle(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const path = try parseJsonStringField(gpa, arguments, "path");
    defer gpa.free(path);
    return std.fmt.allocPrint(gpa, "write_file {s}", .{path});
}

fn formatEditFileTitle(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const input = try parseJsonStringField(gpa, arguments, "input");
    defer gpa.free(input);
    return formatEditFileTitleFromPatch(gpa, input);
}

fn parseJsonStringField(
    gpa: std.mem.Allocator,
    arguments: []const u8,
    field: []const u8,
) ![]u8 {
    assert(arguments.len > 0);
    assert(field.len > 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    const value = parsed.value.object.get(field) orelse return error.MissingField;
    if (value != .string) return error.InvalidToolArguments;
    return gpa.dupe(u8, value.string);
}

fn formatEditFileTitleFromPatch(gpa: std.mem.Allocator, patch: []const u8) ![]u8 {
    var first_path: ?[]const u8 = null;
    var extra_count: u32 = 0;
    var iter = std.mem.splitScalar(u8, patch, '\n');
    while (iter.next()) |raw_line| {
        const line = trimTrailingCR(raw_line);
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "@@")) continue;
        const path = std.mem.trim(u8, trimmed[2..], " \t");
        if (path.len == 0) continue;
        if (first_path == null) {
            first_path = path;
            continue;
        }
        extra_count += 1;
    }
    const path = first_path orelse return error.NoPath;
    if (extra_count == 0) return std.fmt.allocPrint(gpa, "edit_file {s}", .{path});
    return std.fmt.allocPrint(gpa, "edit_file {s} (+{d} more)", .{ path, extra_count });
}

fn trimTrailingCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
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
