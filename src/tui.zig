const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent_mod = @import("agent.zig");
const openai_mod = @import("openai.zig");
const transcript_mod = @import("transcript.zig");

const logo_bytes_max = 64 * 1024;
const loading_spinners = [4][]const u8{ "Firing Neurons", "Multiplying Matrices", "brr..brr...", "Warping" };
const loading_frames = [8][]const u8{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
const loading_frame_ms = 83;

pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    transcript: transcript_mod.Transcript = .{},
    input: vxfw.TextField,
    worker_context: AgentWorkerContext,
    turn_future: ?std.Io.Future(void) = null,
    in_flight: bool = false,
    loading_index: ?u32 = null,
    loading_frame: u8 = 0,
    loading_word_index: u8 = 0,
    loading_tick_active: bool = false,
    agent_index: ?u32 = null,
    thinking_index: ?u32 = null,
    tool_seen_in_response: bool = false,
    pending_redraw: bool = false,
    transcript_auto_scroll: bool = true,
    tool_indexes: std.ArrayList(?u32) = .empty,
    transcript_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 4,
    },

    pub fn init(io: std.Io, gpa: std.mem.Allocator, agent: *agent_mod.Agent) App {
        return .{
            .io = io,
            .gpa = gpa,
            .agent = agent,
            .input = .init(gpa),
            .worker_context = .{
                .io = io,
                .gpa = agent.gpa,
                .agent = agent,
            },
        };
    }

    pub fn deinit(self: *App) void {
        self.awaitTurn();
        self.worker_context.queue.deinit(self.worker_context.io, self.worker_context.gpa);
        self.tool_indexes.deinit(self.gpa);
        self.transcript.deinit(self.gpa);
        self.input.deinit();
        self.* = undefined;
    }

    fn awaitTurn(self: *App) void {
        if (self.turn_future) |*future| {
            future.await(self.io);
            self.turn_future = null;
        }
    }

    pub fn beginSubmit(self: *App) !?u32 {
        if (self.in_flight) return null;
        const prompt = try self.input.toOwnedSlice();
        defer self.gpa.free(prompt);
        if (prompt.len == 0) return null;

        self.resetTurnState();
        _ = try self.transcript.append(self.gpa, .user, "you", prompt);
        try self.agent.addUser(prompt);
        try self.appendLoading();
        self.in_flight = true;
        return self.loading_index;
    }

    fn resetTurnState(self: *App) void {
        self.agent_index = null;
        self.thinking_index = null;
        self.loading_index = null;
        self.loading_frame = 0;
        self.loading_word_index = chooseLoadingWordIndex(self.io);
        self.tool_seen_in_response = false;
        self.pending_redraw = false;
        self.transcript_auto_scroll = true;
        self.tool_indexes.clearRetainingCapacity();
    }

    pub fn startTurn(self: *App) !void {
        self.turn_future = try self.io.concurrent(runAgentTurn, .{
            self.agent,
            &self.worker_context,
        });
    }

    fn appendLoading(self: *App) !void {
        std.debug.assert(self.loading_index == null);
        std.debug.assert(self.loading_word_index < loading_spinners.len);
        self.loading_index = try self.transcript.append(
            self.gpa,
            .status,
            loading_spinners[self.loading_word_index],
            "",
        );
    }

    fn removeLoading(self: *App) void {
        const index = self.loading_index orelse return;
        self.loading_index = null;
        if (index < self.transcript.messages.items.len) {
            self.transcript.remove(self.gpa, index);
        }
    }

    fn advanceLoadingFrame(self: *App) void {
        std.debug.assert(loading_frames.len > 0);
        self.loading_frame +%= 1;
        if (self.loading_frame >= loading_frames.len) self.loading_frame = 0;
    }

    pub fn applyAgentEvent(self: *App, event: agent_mod.Agent.StreamEvent) !bool {
        switch (event) {
            .content_delta => |delta| {
                self.removeLoading();
                _ = try self.finishThinking();
                try self.applyContentDelta(delta);
                self.pending_redraw = true;
                return delta.len > 0;
            },
            .reasoning_delta => |delta| {
                self.removeLoading();
                if (try self.applyReasoningDelta(delta)) {
                    self.pending_redraw = true;
                }
                return false;
            },
            .tool_delta => |tool| {
                const thinking_finished = try self.finishThinking();
                if (try self.applyToolDelta(tool)) {
                    self.pending_redraw = true;
                }
                if (thinking_finished) {
                    self.pending_redraw = true;
                }
                return false;
            },
            .delta_end => {
                const redraw = self.pending_redraw;
                self.pending_redraw = false;
                if (self.shouldShowResponseLoading()) {
                    try self.appendLoading();
                    return true;
                }
                return redraw;
            },
            .tool_finished => |tool| {
                self.removeLoading();
                const thinking_finished = try self.finishThinking();
                return thinking_finished or try self.applyToolFinished(tool);
            },
            .tool_batch_finished => {
                self.removeLoading();
                const thinking_finished = try self.finishThinking();
                self.agent_index = null;
                self.thinking_index = null;
                self.tool_seen_in_response = false;
                self.tool_indexes.clearRetainingCapacity();
                try self.appendLoading();
                _ = thinking_finished;
                return true;
            },
            .turn_failed => |message| {
                self.removeLoading();
                _ = try self.transcript.append(self.gpa, .agent, "agent", message);
                return true;
            },
            .turn_finished => {
                self.removeLoading();
                _ = try self.finishThinking();
                self.in_flight = false;
                self.awaitTurn();
                return true;
            },
        }
    }

    fn shouldShowResponseLoading(self: *const App) bool {
        if (!self.in_flight) return false;
        if (self.loading_index != null) return false;
        if (self.thinking_index == null) return false;
        if (self.agent_index != null) return false;
        if (self.tool_seen_in_response) return false;
        return true;
    }

    fn applyContentDelta(self: *App, delta: []const u8) !void {
        if (delta.len == 0) return;
        if (self.agent_index) |index| {
            try self.transcript.appendAgentDelta(self.gpa, index, delta);
        } else {
            self.agent_index = try self.transcript.append(self.gpa, .agent, "agent", delta);
        }
        if (!self.tool_seen_in_response) {
            self.selectGeneratedMessage(self.agent_index.?);
            self.transcript_auto_scroll = true;
        }
    }

    fn finishThinking(self: *App) !bool {
        const index = self.thinking_index orelse return false;
        if (index >= self.transcript.messages.items.len) return false;
        if (std.mem.eql(u8, self.transcript.messages.items[index].title, "Thoughts")) return false;
        try self.transcript.finishThinking(self.gpa, index);
        return true;
    }

    fn applyReasoningDelta(self: *App, delta: []const u8) !bool {
        if (delta.len == 0) return false;
        var visible_change = false;
        if (self.thinking_index) |index| {
            try self.transcript.appendThinkingDelta(self.gpa, index, delta);
        } else if (self.agent_index) |agent_index| {
            self.thinking_index = try self.transcript.insert(
                self.gpa,
                agent_index,
                .thinking,
                "Thinking...",
                delta,
            );
            self.agent_index = agent_index + 1;
            self.transcript.select(self.thinking_index.?);
            visible_change = true;
        } else {
            self.thinking_index = try self.transcript.append(self.gpa, .thinking, "Thinking...", delta);
            visible_change = true;
        }
        if (self.agent_index == null and !self.tool_seen_in_response) {
            self.selectGeneratedMessage(self.thinking_index.?);
        }
        return visible_change;
    }

    fn applyToolDelta(self: *App, tool: agent_mod.Agent.StreamEvent.ToolDelta) !bool {
        if (!std.mem.eql(u8, tool.name, "bash")) return false;
        const command = agent_mod.parseCommand(self.gpa, tool.arguments) catch return false;
        defer self.gpa.free(command);

        self.removeLoading();
        var visible_change = false;
        if (self.toolTranscriptIndex(tool.index)) |index| {
            visible_change = !toolTitleMatchesCommand(self.transcript.messages.items[index].title, command);
            try self.transcript.updateTool(self.gpa, index, command);
        } else {
            const index = try self.transcript.startTool(self.gpa, command);
            try self.putToolTranscriptIndex(tool.index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        return visible_change;
    }

    fn applyToolFinished(self: *App, tool: agent_mod.Agent.StreamEvent.ToolFinished) !bool {
        const existing_index = self.toolTranscriptIndex(tool.index);
        const index = if (existing_index) |index| index else index: {
            const created = try self.transcript.startTool(self.gpa, tool.command);
            try self.putToolTranscriptIndex(tool.index, created);
            break :index created;
        };

        const visible_before = self.toolFinishVisibleChange(index, tool.command);
        try self.transcript.updateTool(self.gpa, index, tool.command);
        try self.transcript.finishTool(self.gpa, index, tool.body);
        self.selectGeneratedMessage(index);
        self.tool_seen_in_response = true;
        return existing_index == null or visible_before;
    }

    fn selectGeneratedMessage(self: *App, index: u32) void {
        if (self.transcript.selected) |selected| {
            if (selected != index) return;
        }
        self.transcript.select(index);
    }

    fn toolFinishVisibleChange(self: *const App, index: u32, command: []const u8) bool {
        if (index >= self.transcript.messages.items.len) return true;
        const message = self.transcript.messages.items[index];
        if (message.kind != .tool) return true;
        if (message.expanded) return true;
        return !toolTitleMatchesCommand(message.title, command);
    }

    fn toolTranscriptIndex(self: *const App, tool_index: usize) ?u32 {
        if (tool_index >= self.tool_indexes.items.len) return null;
        return self.tool_indexes.items[tool_index];
    }

    fn putToolTranscriptIndex(self: *App, tool_index: usize, transcript_index: u32) !void {
        while (self.tool_indexes.items.len <= tool_index) {
            try self.tool_indexes.append(self.gpa, null);
        }
        self.tool_indexes.items[tool_index] = transcript_index;
    }

    pub fn handleCommandKey(self: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            self.transcript.moveSelection(.previous);
            self.transcript_auto_scroll = false;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.transcript.moveSelection(.next);
            self.transcript_auto_scroll = self.selectionIsLastMessage();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            self.transcript.toggleSelected();
            return true;
        }
        return false;
    }

    fn selectionIsLastMessage(self: *const App) bool {
        const selected = self.transcript.selected orelse return false;
        if (self.transcript.messages.items.len == 0) return false;
        return selected == self.transcript.messages.items.len - 1;
    }
};

fn toolTitleMatchesCommand(title: []const u8, command: []const u8) bool {
    const prefix = "$ ";
    return std.mem.startsWith(u8, title, prefix) and
        std.mem.eql(u8, title[prefix.len..], command);
}

fn chooseLoadingWordIndex(io: std.Io) u8 {
    std.debug.assert(loading_spinners.len > 0);
    const timestamp: std.Io.Timestamp = .now(io, .awake);
    const index = @mod(timestamp.nanoseconds, loading_spinners.len);
    return @intCast(index);
}

const AgentEventQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(*agent_mod.Agent.StreamEvent) = .empty,

    fn push(
        self: *AgentEventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        event: *agent_mod.Agent.StreamEvent,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.items.append(gpa, event);
    }

    fn drainInto(
        self: *AgentEventQueue,
        io: std.Io,
        gpa: std.mem.Allocator,
        sink: *std.ArrayList(*agent_mod.Agent.StreamEvent),
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try sink.appendSlice(gpa, self.items.items);
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *AgentEventQueue, io: std.Io, gpa: std.mem.Allocator) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        for (self.items.items) |event_ptr| {
            event_ptr.deinit(gpa);
            gpa.destroy(event_ptr);
        }
        self.items.deinit(gpa);
    }
};

const AgentWorkerContext = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: *agent_mod.Agent,
    queue: AgentEventQueue = .{},
};

fn runAgentTurn(agent: *agent_mod.Agent, worker_context: *AgentWorkerContext) void {
    agent.turn(.{
        .context = worker_context,
        .post = postAgentEvent,
    }) catch |err| {
        const message = std.fmt.allocPrint(
            worker_context.gpa,
            "agent turn failed: {s}",
            .{@errorName(err)},
        ) catch return;
        postAgentEvent(worker_context, .{ .turn_failed = message }) catch {
            worker_context.gpa.free(message);
            return;
        };
    };
    postAgentEvent(worker_context, .turn_finished) catch {};
}

fn postAgentEvent(context: ?*anyopaque, event: agent_mod.Agent.StreamEvent) !void {
    const worker_context: *AgentWorkerContext = @ptrCast(@alignCast(context.?));
    var owned_event = event;
    errdefer owned_event.deinit(worker_context.gpa);
    const event_ptr = try worker_context.gpa.create(agent_mod.Agent.StreamEvent);
    errdefer worker_context.gpa.destroy(event_ptr);
    event_ptr.* = owned_event;
    owned_event = .delta_end;
    errdefer event_ptr.deinit(worker_context.gpa);
    try worker_context.queue.push(worker_context.io, worker_context.gpa, event_ptr);
}

pub fn run(init: std.process.Init, agent: *agent_mod.Agent) !void {
    const gpa = init.arena.allocator();
    var tty_buffer: [8192]u8 = undefined;
    var fw_app = try vxfw.App.init(init.io, gpa, init.environ_map, &tty_buffer);
    defer fw_app.deinit();

    var app = App.init(init.io, gpa, agent);
    defer app.deinit();

    const logo = try loadStartupLogo(init.io, gpa);
    defer gpa.free(logo);
    _ = try app.transcript.append(gpa, .logo, "logo", logo);

    var root: RootWidget = .{ .app = &app };
    try fw_app.run(root.widget(), .{});
}

fn loadStartupLogo(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var cwd = std.Io.Dir.cwd();
    return cwd.readFileAllocOptions(io, "src/assets/logo.txt", gpa, .limited(logo_bytes_max), .of(u8), 0);
}

const RootWidget = struct {
    app: *App,
    spinner_tick_accum: u32 = 0,

    fn widget(self: *RootWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = captureEvent,
            .eventHandler = handleEvent,
            .drawFn = drawRoot,
        };
    }

    fn captureEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try ctx.requestFocus(self.app.input.widget());
                ctx.consumeAndRedraw();
            },
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) self.app.transcript_auto_scroll = false;
                if (mouse.button == .wheel_down) self.app.transcript_auto_scroll = !self.app.transcript_list.scroll.has_more;
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                    ctx.quit = true;
                    ctx.consume_event = true;
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    try self.submit(ctx);
                    return;
                }
                if (try self.app.handleCommandKey(key)) {
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .tick => try self.handleTick(ctx),
            else => {},
        }
    }

    const drain_tick_ms: u32 = 30;
    const spinner_tick_threshold_ms: u32 = loading_frame_ms;

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        var visible_change = try self.drainAgentEvents(ctx);

        if (self.app.loading_index) |_| {
            self.spinner_tick_accum += drain_tick_ms;
            if (self.spinner_tick_accum >= spinner_tick_threshold_ms) {
                self.spinner_tick_accum = 0;
                self.app.advanceLoadingFrame();
                visible_change = true;
            }
        } else {
            self.spinner_tick_accum = 0;
        }

        const should_tick = self.app.in_flight or self.app.loading_index != null;
        if (should_tick) {
            try ctx.tick(drain_tick_ms, self.widget());
        } else {
            self.app.loading_tick_active = false;
        }

        if (visible_change) {
            ctx.consumeAndRedraw();
        } else {
            ctx.consumeEvent();
        }
    }

    fn startLoadingTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        if (self.app.loading_tick_active) return;
        self.app.loading_tick_active = true;
        self.spinner_tick_accum = 0;
        try ctx.tick(drain_tick_ms, self.widget());
    }

    fn submit(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        const loading_index = (try self.app.beginSubmit()) orelse return;
        _ = loading_index;
        try self.app.startTurn();
        try self.startLoadingTick(ctx);
        ctx.consumeAndRedraw();
    }

    fn drainAgentEvents(self: *RootWidget, ctx: *vxfw.EventContext) !bool {
        const worker_io = self.app.worker_context.io;
        const worker_gpa = self.app.worker_context.gpa;
        var batch: std.ArrayList(*agent_mod.Agent.StreamEvent) = .empty;
        defer batch.deinit(worker_gpa);
        try self.app.worker_context.queue.drainInto(worker_io, worker_gpa, &batch);

        var visible_change = false;
        for (batch.items) |event_ptr| {
            defer worker_gpa.destroy(event_ptr);
            defer event_ptr.deinit(worker_gpa);

            if (self.app.loading_index != null) try self.startLoadingTick(ctx);
            if (try self.app.applyAgentEvent(event_ptr.*)) visible_change = true;
            if (self.app.loading_index != null) try self.startLoadingTick(ctx);
        }
        return visible_change;
    }

    fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const input_height: u16 = @min(max_height, 3);
        const transcript_height: u16 = max_height - input_height;

        var transcript_view: TranscriptWidget = .{ .app = self.app };
        var input_view: InputWidget = .{ .app = self.app };

        const transcript_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = transcript_height },
            .{ .width = max_width, .height = transcript_height },
        );
        const input_ctx = ctx.withConstraints(
            .{ .width = max_width, .height = input_height },
            .{ .width = max_width, .height = input_height },
        );

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try transcript_view.widget().draw(transcript_ctx),
            .z_index = 0,
        };
        children[1] = .{
            .origin = .{ .row = transcript_height, .col = 0 },
            .surface = try input_view.widget().draw(input_ctx),
            .z_index = 0,
        };

        return .{
            .size = .{ .width = max_width, .height = max_height },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

const ConversationLayout = struct {
    const left: u16 = 2;
    const right: u16 = 2;
    const top: u16 = 1;
    const bottom: u16 = 1;

    fn verticalPadding() @TypeOf(vxfw.Padding.vertical(0)) {
        return .{
            .top = top,
            .bottom = bottom,
        };
    }

    fn contentWidth(width: u16) u16 {
        return width -| left -| right;
    }
};

const TranscriptWidget = struct {
    app: *App,

    fn widget(self: *TranscriptWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawTranscript,
        };
    }

    fn drawTranscript(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *TranscriptWidget = @ptrCast(@alignCast(ptr));
        const widgets = try self.messageWidgets(ctx);
        self.app.transcript_list.children = .{ .slice = widgets };
        self.app.transcript_list.item_count = @intCast(widgets.len);
        self.syncCursor(ctx);

        var list_padding: vxfw.Padding = .{
            .child = self.app.transcript_list.widget(),
            .padding = ConversationLayout.verticalPadding(),
        };
        return list_padding.widget().draw(ctx);
    }

    fn messageWidgets(self: *TranscriptWidget, ctx: vxfw.DrawContext) ![]vxfw.Widget {
        const messages = self.app.transcript.messages.items;
        const widgets = try ctx.arena.alloc(vxfw.Widget, messages.len);
        const bodies = try ctx.arena.alloc(MessageWidget, messages.len);
        for (messages, 0..) |message, index| {
            const selected = if (self.app.transcript.selected) |selected_index| selected_index == index else false;
            bodies[index] = .{ .message = message, .selected = selected, .loading_frame = self.app.loading_frame };
            widgets[index] = bodies[index].widget();
        }
        return widgets;
    }

    fn syncCursor(self: *TranscriptWidget, ctx: vxfw.DrawContext) void {
        const cursor = self.app.loading_index orelse self.app.transcript.selected orelse 0;
        const cursor_changed = self.app.transcript_list.cursor != cursor;
        self.app.transcript_list.cursor = cursor;
        if (self.app.transcript_auto_scroll) {
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        if (cursor_changed) self.app.transcript_list.ensureScroll();
    }

    fn scrollCursorToTail(self: *TranscriptWidget, ctx: vxfw.DrawContext, cursor: u32) void {
        if (cursor >= self.app.transcript.messages.items.len) return;
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const list_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        const message = self.app.transcript.messages.items[cursor];
        const message_height = messageRows(message, ConversationLayout.contentWidth(max_width));
        self.app.transcript_list.scroll.top = cursor;
        self.app.transcript_list.scroll.pending_lines = 0;
        self.app.transcript_list.scroll.wants_cursor = false;
        if (message_height > list_height) {
            self.app.transcript_list.scroll.offset = @intCast(message_height - list_height);
        } else {
            self.app.transcript_list.scroll.offset = 0;
        }
    }
};

const MessageWidget = struct {
    message: transcript_mod.Message,
    selected: bool,
    loading_frame: u8,

    fn widget(self: *MessageWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *MessageWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const height = messageRows(self.message, ConversationLayout.contentWidth(width));
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        self.drawBody(&surface, ctx);
        return surface;
    }

    fn drawBody(self: *MessageWidget, surface: *vxfw.Surface, ctx: vxfw.DrawContext) void {
        var row: u16 = 0;
        fillRow(surface, row, self.selected);
        row += 1;
        switch (self.message.kind) {
            .user => drawWrapped(surface, self.message.body, StylePalette.user, self.selected, &row, ctx, 2, StylePalette.user),
            .agent => drawWrapped(surface, self.message.body, .{}, self.selected, &row, ctx, 0, null),
            .logo => drawLogo(surface, self.message.body, &row, ctx),
            .tool => {
                drawLine(surface, self.message.title, StylePalette.tool, self.selected, &row, ctx, 0, null);
                if (self.message.expanded) drawWrapped(surface, self.message.body, StylePalette.tool, self.selected, &row, ctx, 0, null);
            },
            .thinking => {
                drawLine(surface, self.message.title, StylePalette.thinking_label, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
                if (self.message.expanded) drawWrapped(surface, self.message.body, StylePalette.thinking_body, self.selected, &row, ctx, 2, StylePalette.thinking_bar);
            },
            .status => drawLoading(surface, self.message.title, self.loading_frame, &row, ctx),
        }
        fillRow(surface, row, self.selected);
    }

    fn drawLoading(
        surface: *vxfw.Surface,
        text: []const u8,
        loading_frame: u8,
        row: *u16,
        ctx: vxfw.DrawContext,
    ) void {
        std.debug.assert(loading_frame < loading_frames.len);
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, false);
        writeText(surface, loading_frames[loading_frame], StylePalette.thinking_label, false, row.*, ctx, 0);
        writeText(surface, text, StylePalette.thinking_body, false, row.*, ctx, 2);
        row.* += 1;
    }

    fn drawLogo(surface: *vxfw.Surface, text: []const u8, row: *u16, ctx: vxfw.DrawContext) void {
        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            writeGradient(surface, text[line_start..line_end], row.*, ctx);
            row.* += 1;
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawWrapped(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        const content_width = ConversationLayout.contentWidth(surface.size.width);
        const width = @max(@as(usize, content_width -| indent), 1);
        if (text.len == 0) {
            drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            return;
        }

        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            if (line_start == line_end) {
                drawLine(surface, "", style, selected, row, ctx, indent, bar_style);
            } else {
                var chunk_start = line_start;
                while (chunk_start < line_end) {
                    const chunk_end = @min(chunk_start + width, line_end);
                    drawLine(surface, text[chunk_start..chunk_end], style, selected, row, ctx, indent, bar_style);
                    chunk_start = chunk_end;
                }
            }
            if (line_end == text.len) break;
            line_start = line_end + 1;
        }
    }

    fn drawLine(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: *u16,
        ctx: vxfw.DrawContext,
        indent: u16,
        bar_style: ?vaxis.Style,
    ) void {
        if (row.* >= surface.size.height) return;
        fillRow(surface, row.*, selected);
        if (bar_style) |active_bar_style| writeText(surface, "┃", active_bar_style, selected, row.*, ctx, 0);
        writeText(surface, text, style, selected, row.*, ctx, indent);
        row.* += 1;
    }

    fn fillRow(surface: *vxfw.Surface, row: u16, selected: bool) void {
        if (!selected) return;
        var col: u16 = 0;
        while (col < surface.size.width) : (col += 1) {
            surface.writeCell(col, row, .{ .style = StylePalette.selected });
        }
    }

    fn writeText(
        surface: *vxfw.Surface,
        text: []const u8,
        style: vaxis.Style,
        selected: bool,
        row: u16,
        ctx: vxfw.DrawContext,
        start_col: u16,
    ) void {
        var col = ConversationLayout.left + start_col;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = mergedSelectedStyle(style, selected),
            });
            col += width;
        }
    }

    fn writeGradient(surface: *vxfw.Surface, text: []const u8, row: u16, ctx: vxfw.DrawContext) void {
        const gradient_width: u16 = @max(@min(ctx.stringWidth(text), std.math.maxInt(u16)), 1);
        var col: u16 = ConversationLayout.left;
        const col_limit = surface.size.width -| ConversationLayout.right;
        var iter = ctx.graphemeIterator(text);
        while (iter.next()) |grapheme| {
            if (col >= col_limit) return;
            const bytes = grapheme.bytes(text);
            const width: u8 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > col_limit) return;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = width },
                .style = gradientStyle(col - ConversationLayout.left, gradient_width, false),
            });
            col += width;
        }
    }
};

const InputWidget = struct {
    app: *App,

    fn widget(self: *InputWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawInput,
        };
    }

    fn drawInput(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *InputWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse 0;
        const height: u16 = 3;

        var prompt: vxfw.Text = .{
            .text = ">",
            .softwrap = false,
            .width_basis = .parent,
        };
        var prompt_box: vxfw.SizedBox = .{
            .child = prompt.widget(),
            .size = .{ .width = 2, .height = 1 },
        };
        var input_box: vxfw.SizedBox = .{
            .child = self.app.input.widget(),
            .size = .{ .width = max_width -| 2, .height = 1 },
        };
        var row: vxfw.FlexRow = .{
            .children = &.{
                .{ .widget = prompt_box.widget(), .flex = 0 },
                .{ .widget = input_box.widget(), .flex = 1 },
            },
        };
        var row_box: vxfw.SizedBox = .{
            .child = row.widget(),
            .size = .{ .width = max_width -| 2, .height = 1 },
        };
        var border: vxfw.Border = .{
            .child = row_box.widget(),
            .style = StylePalette.thinking_body,
            .labels = &.{.{ .text = "Paladin", .alignment = .top_left }},
        };
        var box: vxfw.SizedBox = .{
            .child = border.widget(),
            .size = .{ .width = max_width, .height = height },
        };
        return box.widget().draw(ctx);
    }
};

const RowViewport = struct {
    first: u32,
    height: u16,
};

fn visibleRows(
    messages: []const transcript_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) RowViewport {
    const total = transcriptRows(messages, width);
    if (total <= height) return .{ .first = 0, .height = height };

    const selected_index = selected orelse return .{
        .first = total - height,
        .height = height,
    };
    std.debug.assert(selected_index < messages.len);

    const last_index: u32 = @intCast(messages.len - 1);
    if (selected_index == last_index) {
        return .{ .first = total - height, .height = height };
    }

    const selected_start = messageStartRow(messages, selected_index, width);
    const selected_rows = messageRows(messages[selected_index], width);
    const selected_end = selected_start + selected_rows;
    if (selected_rows >= height) {
        return .{ .first = selected_start, .height = height };
    }
    if (selected_end <= height) {
        return .{ .first = 0, .height = height };
    }
    return .{ .first = selected_end - height, .height = height };
}

const StylePalette = struct {
    const thinking_blue = .{ 96, 165, 250 };
    const user_yellow = .{ 212, 175, 55 };

    const selected: vaxis.Style = .{ .bg = .{ .rgb = .{ 38, 38, 38 } } };
    const user: vaxis.Style = .{ .fg = .{ .rgb = user_yellow }, .italic = true };
    const tool: vaxis.Style = .{ .fg = .{ .rgb = .{ 34, 197, 94 } } };
    const thinking_label: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
    const thinking_body: vaxis.Style = .{ .fg = .{ .rgb = .{ 138, 138, 138 } } };
    const thinking_bar: vaxis.Style = .{ .fg = .{ .rgb = thinking_blue } };
};

fn mergedSelectedStyle(style: vaxis.Style, selected: bool) vaxis.Style {
    var merged = style;
    if (selected) merged.bg = StylePalette.selected.bg;
    return merged;
}

fn gradientStyle(col: u16, width: u16, selected: bool) vaxis.Style {
    std.debug.assert(width > 0);
    const denominator: u32 = @max(@as(u32, width) - 1, 1);
    const numerator: u32 = @min(@as(u32, col), denominator);
    const yellow = .{ 252, 211, 77 };
    const orange = .{ 249, 115, 22 };
    return mergedSelectedStyle(.{ .fg = .{ .rgb = .{
        gradientChannel(yellow[0], orange[0], numerator, denominator),
        gradientChannel(yellow[1], orange[1], numerator, denominator),
        gradientChannel(yellow[2], orange[2], numerator, denominator),
    } } }, selected);
}

fn gradientChannel(start: u8, end: u8, numerator: u32, denominator: u32) u8 {
    std.debug.assert(denominator > 0);
    const start_value: u32 = start;
    const end_value: u32 = end;
    if (end_value >= start_value) {
        return @intCast(start_value + ((end_value - start_value) * numerator) / denominator);
    }
    return @intCast(start_value - ((start_value - end_value) * numerator) / denominator);
}

fn firstVisibleMessage(
    messages: []const transcript_mod.Message,
    selected: ?u32,
    width: u16,
    height: u16,
) u32 {
    const first_row = visibleRows(messages, selected, width, height).first;
    var row: u32 = 0;
    var index: u32 = 0;
    while (index < messages.len) : (index += 1) {
        const next = row + messageRows(messages[index], width);
        if (next > first_row) return index;
        row = next;
    }
    return 0;
}

fn transcriptRows(messages: []const transcript_mod.Message, width: u16) u32 {
    var rows: u32 = 0;
    for (messages) |message| {
        rows += messageRows(message, width);
    }
    return rows;
}

fn messageStartRow(messages: []const transcript_mod.Message, index: u32, width: u16) u32 {
    std.debug.assert(index < messages.len);
    var rows: u32 = 0;
    var current: u32 = 0;
    while (current < index) : (current += 1) {
        rows += messageRows(messages[current], width);
    }
    return rows;
}

fn messageRows(message: transcript_mod.Message, width: u16) u16 {
    return messageContentRows(message, width) + 2;
}

fn messageContentRows(message: transcript_mod.Message, width: u16) u16 {
    return switch (message.kind) {
        .user => textRows(message.body, width -| 2),
        .agent => textRows(message.body, width),
        .logo => logoRows(message.body),
        .thinking => if (message.expanded)
            1 + textRows(message.body, width -| 2)
        else
            1,
        .status => 1,
        .tool => if (message.expanded)
            1 + textRows(message.body, width)
        else
            1,
    };
}

fn logoRows(text: []const u8) u16 {
    if (text.len == 0) return 1;
    var rows: u16 = 1;
    for (text) |byte| {
        if (byte == '\n') rows += 1;
    }
    return rows;
}

fn textRows(text: []const u8, width: u16) u16 {
    if (text.len == 0) return 1;
    const row_width = @max(@as(usize, width), 1);
    var rows: u16 = 1;
    var col: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            rows += 1;
            col = 0;
            continue;
        }

        if (col >= row_width) {
            rows += 1;
            col = 0;
        }
        col += 1;
    }
    return rows;
}

test "begin submit clears input and appends loading row before agent turn" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    const loading_index = (try app.beginSubmit()).?;

    try std.testing.expectEqual(@as(usize, 0), app.input.buf.firstHalf().len);
    try std.testing.expectEqual(@as(usize, 0), app.input.buf.secondHalf().len);
    try std.testing.expectEqualStrings("hello", app.transcript.messages.items[0].body);
    try std.testing.expectEqual(.status, app.transcript.messages.items[loading_index].kind);
    try std.testing.expect(isLoadingWord(app.transcript.messages.items[loading_index].title));
    try std.testing.expectEqual(@as(u16, 3), messageRows(app.transcript.messages.items[loading_index], 80));
    try std.testing.expectEqual(@as(u32, 0), app.transcript.selected.?);
}

fn isLoadingWord(text: []const u8) bool {
    for (loading_spinners) |loading_spinner| {
        if (std.mem.eql(u8, text, loading_spinner)) return true;
    }
    return false;
}

test "empty text deltas do not create selectable messages" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .content_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.transcript.messages.items[0].kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .reasoning_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.transcript.messages.items[0].kind);
}

test "agent app events update transcript on the ui side" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .reasoning_delta = "checking" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .reasoning_delta = " files" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "ls",
        .body = "$ ls\nexit 0\nstdout:\n\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.transcript.messages.items[0].kind);
    try std.testing.expectEqual(.thinking, app.transcript.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[2].kind);
    try std.testing.expectEqual(@as(u32, 2), app.transcript.selected.?);
    try std.testing.expectEqualStrings("checking files", app.transcript.messages.items[1].body);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[2].title);
}

test "user can navigate away from a streaming thinking block" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .reasoning_delta = "first chunk" });
    try std.testing.expectEqual(.thinking, app.transcript.messages.items[app.transcript.selected.?].kind);

    app.transcript.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.transcript.messages.items[app.transcript.selected.?].kind);

    _ = try app.applyAgentEvent(.{ .reasoning_delta = " more" });
    try std.testing.expectEqual(.user, app.transcript.messages.items[app.transcript.selected.?].kind);
}

test "user can navigate away from a streaming agent message" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("hello");
    _ = (try app.beginSubmit()).?;

    _ = try app.applyAgentEvent(.{ .content_delta = "first chunk" });
    try std.testing.expectEqual(.agent, app.transcript.messages.items[app.transcript.selected.?].kind);

    app.transcript.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.transcript.messages.items[app.transcript.selected.?].kind);

    _ = try app.applyAgentEvent(.{ .content_delta = " more" });
    try std.testing.expectEqual(.user, app.transcript.messages.items[app.transcript.selected.?].kind);
}

test "tool row persists through finish and turn completion" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 2), app.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[1].title);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "ls",
        .body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[1].title);

    try std.testing.expect(try app.applyAgentEvent(.turn_finished));
    try std.testing.expectEqual(@as(usize, 2), app.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[1].title);
}

test "partial tool arguments do not create visible tool rows" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.transcript.messages.items[0].kind);
    try std.testing.expectEqual(.status, app.transcript.messages.items[1].kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[1].title);
}

test "tool finish creates row if no complete streamed arguments appeared" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run ls");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "ls",
        .body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 2), app.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[1].title);
}

test "new tool response index creates a new transcript row" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run tools");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "ls",
        .body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[2].kind);
    try std.testing.expectEqualStrings("$ ls", app.transcript.messages.items[1].title);
    try std.testing.expectEqualStrings("$ pwd", app.transcript.messages.items[2].title);
}

test "late tool finish does not move selection upward" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("run tools");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"ls\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 1), app.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "ls",
        .body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .content_delta = "done" }));
    try std.testing.expectEqual(@as(u32, 3), app.transcript.selected.?);
}

test "loading resumes after post-tool thinking delta" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "pwd",
        .body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .reasoning_delta = "checking output" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));

    try std.testing.expectEqual(@as(usize, 4), app.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.transcript.messages.items[0].kind);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[1].kind);
    try std.testing.expectEqual(.thinking, app.transcript.messages.items[2].kind);
    try std.testing.expectEqual(.status, app.transcript.messages.items[3].kind);
    try std.testing.expectEqualStrings("Thinking...", app.transcript.messages.items[2].title);
    try std.testing.expect(isLoadingWord(app.transcript.messages.items[3].title));
}

test "agent response after tool batch appears below tool rows" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(try app.applyAgentEvent(.{ .content_delta = "I will check." }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "pwd",
        .body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .content_delta = "The repo is in /tmp." }));

    try std.testing.expectEqual(@as(usize, 4), app.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.transcript.messages.items[0].kind);
    try std.testing.expectEqual(.agent, app.transcript.messages.items[1].kind);
    try std.testing.expectEqual(.tool, app.transcript.messages.items[2].kind);
    try std.testing.expectEqual(.agent, app.transcript.messages.items[3].kind);
    try std.testing.expectEqualStrings("I will check.", app.transcript.messages.items[1].body);
    try std.testing.expectEqualStrings("$ pwd", app.transcript.messages.items[2].title);
    try std.testing.expectEqualStrings("The repo is in /tmp.", app.transcript.messages.items[3].body);
    try std.testing.expectEqual(@as(u32, 3), app.transcript.selected.?);
}

test "content delta after tool preview does not move selection away from tool row" {
    const gpa = std.testing.allocator;
    var openai_client: openai_mod.Client = .{
        .gpa = gpa,
        .io = std.testing.io,
        .config = .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" },
    };
    var agent = agent_mod.Agent.init(gpa, std.testing.io, .{ .openai = &openai_client });
    defer agent.deinit();

    var app = App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.input.insertSliceAtCursor("inspect");
    _ = (try app.beginSubmit()).?;

    try std.testing.expect(try app.applyAgentEvent(.{ .content_delta = "I will check." }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 1), app.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 2), app.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .content_delta = " Still checking." }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(u32, 2), app.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_finished = .{
        .index = 0,
        .command = "pwd",
        .body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.transcript.selected.?);
    try std.testing.expectEqualStrings("I will check. Still checking.", app.transcript.messages.items[1].body);
    try std.testing.expectEqualStrings("$ pwd", app.transcript.messages.items[2].title);
}

test "collapsed thinking and tool rows have stable heights" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const thinking_index = try transcript.append(gpa, .thinking, "Thinking...", "short");
    try std.testing.expectEqual(@as(u16, 3), messageRows(transcript.messages.items[thinking_index], 80));

    try transcript.appendThinkingDelta(gpa, thinking_index, " ");
    try transcript.appendThinkingDelta(gpa, thinking_index, "this is a much longer thinking body that should not change the collapsed row height");
    try std.testing.expectEqual(@as(u16, 3), messageRows(transcript.messages.items[thinking_index], 80));

    const tool_index = try transcript.startTool(gpa, "pwd");
    try std.testing.expectEqual(@as(u16, 3), messageRows(transcript.messages.items[tool_index], 80));
}

test "first visible message tracks bottom viewport row" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "you", "one");
    _ = try transcript.append(gpa, .agent, "agent", "two");
    _ = try transcript.append(gpa, .agent, "agent", "three");

    try std.testing.expectEqual(
        @as(u32, 1),
        firstVisibleMessage(transcript.messages.items, transcript.selected, 80, 6),
    );
}

test "latest tall message scrolls by rows instead of message boundaries" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .agent, "agent", "one");
    _ = try transcript.append(gpa, .agent, "agent", "line1\nline2\nline3\nline4\nline5\nline6");

    const viewport = visibleRows(transcript.messages.items, transcript.selected, 80, 4);
    try std.testing.expectEqual(@as(u32, 7), viewport.first);
    try std.testing.expectEqual(@as(u32, 11), transcriptRows(transcript.messages.items, 80));
}

test "collapsed tool messages render no body text" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "printf hello");
    try transcript.finishTool(gpa, index, "stdout:\nhello\nstderr:\n");

    try std.testing.expect(!transcript.messages.items[index].expanded);
    try std.testing.expectEqual(@as(u16, 3), messageRows(transcript.messages.items[index], 80));
    transcript.toggleSelected();
    try std.testing.expect(transcript.messages.items[index].expanded);
    try std.testing.expectEqualStrings("stdout:\nhello\nstderr:\n", transcript.messages.items[index].body);
}

test "selected collapsed tools stay visible for tight viewport heights" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .agent, "agent", "one two three four five six seven eight nine ten");
    const tool_index = try transcript.startTool(gpa, "zig build test");
    _ = try transcript.append(gpa, .agent, "agent", "done");

    transcript.selected = tool_index;
    var height: u16 = 1;
    while (height <= 8) : (height += 1) {
        const first = firstVisibleMessage(transcript.messages.items, transcript.selected, 12, height);
        try std.testing.expect(first <= tool_index);
        try std.testing.expect(selectedRowFits(transcript.messages.items, transcript.selected.?, 12, height));
    }
}

fn selectedRowFits(
    messages: []const transcript_mod.Message,
    selected: u32,
    width: u16,
    height: u16,
) bool {
    const viewport = visibleRows(messages, selected, width, height);
    const selected_start = messageStartRow(messages, selected, width);
    const selected_end = selected_start + messageRows(messages[selected], width);
    const viewport_end = viewport.first + viewport.height;
    return selected_start < viewport_end and selected_end > viewport.first;
}
