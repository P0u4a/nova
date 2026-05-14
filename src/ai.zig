const std = @import("std");

pub const openai = @import("ai/openai.zig");

pub const ReasoningEffort = enum {
    low,
    medium,
    high,
    xhigh,

    pub fn label(self: ReasoningEffort) []const u8 {
        return @tagName(self);
    }
};

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    tools_json: []const u8 = "[]",
    reasoning_effort: ?ReasoningEffort = .medium,
};

/// A tool call preserved on an assistant message in the conversation history.
/// Mirrors OpenAI's `assistant.tool_calls[*]` shape so we can re-serialise it
/// on the next request. Distinct from `ToolCall` (which is the streamed,
/// per-response form) — this one owns its bytes for as long as the message
/// lives in history.
pub const StoredToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,

    pub fn deinit(self: *StoredToolCall, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.arguments);
        self.* = undefined;
    }
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    /// Present only for messages with role="tool". Holds the id of the
    /// assistant tool_call this result is responding to.
    tool_call_id: ?[]const u8 = null,
    /// Present only for messages with role="assistant" that emitted at least
    /// one tool call. The order matches the response's tool_calls order.
    tool_calls: []const StoredToolCall = &.{},
};

pub const ToolCall = struct {
    index: u32,
    id: []u8,
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: *ToolCall, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.arguments);
        self.* = undefined;
    }
};

pub const Response = struct {
    content: []u8,
    reasoning: []u8,
    tool_calls: std.ArrayList(ToolCall) = .empty,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
        gpa.free(self.reasoning);
        for (self.tool_calls.items) |*tool_call| {
            tool_call.deinit(gpa);
        }
        self.tool_calls.deinit(gpa);
        self.* = undefined;
    }
};

pub const StreamObserver = struct {
    context: ?*anyopaque = null,
    on_content_delta: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    on_reasoning_delta: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    on_tool_delta: ?*const fn (?*anyopaque, u32, []const u8, []const u8) anyerror!void = null,
    on_delta_end: ?*const fn (?*anyopaque) anyerror!void = null,
};

pub const AIClient = union(enum) {
    openai: *openai.Client,

    pub fn completeStream(
        self: AIClient,
        messages: []const ChatMessage,
        observer: StreamObserver,
    ) !Response {
        return switch (self) {
            .openai => |c| c.completeStream(messages, observer),
        };
    }
};
