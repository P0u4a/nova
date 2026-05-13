const std = @import("std");

pub const openai = @import("ai/openai.zig");

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    tools_json: []const u8 = "[]",
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
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
