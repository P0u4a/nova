//! The ExecutorService module: runs batches of ToolCalls and produces ToolResults.

const std = @import("std");

const ai = @import("ai.zig");
const background = @import("background.zig");
const bash_safety = @import("bash_safety.zig");
const bash_tool = @import("tools/bash.zig");
const tools = @import("tools.zig");

const assert = std.debug.assert;

/// Wiring for the background-bash path: the shared manager plus an opaque token
/// identifying the agent the job belongs to (the manager hands it back at
/// completion so the UI can route the delivery to the right lane). Threaded in
/// by the agent only when a `BackgroundManager` is attached.
pub const BackgroundStart = struct {
    manager: *background.BackgroundManager,
    owner: *anyopaque,
};

/// The output of one ToolCall. One channel: the observation the model reads is
/// also exactly what the RPC layer forwards to the client as the result content.
pub const ToolResult = struct {
    /// The id this result is responding to.
    call_id: []u8,
    /// The observation, which flows into the assistant's next `tool` role message
    /// in history and out over RPC as the result's text content.
    content: []u8,
    /// The tool's name, as the model emitted it.
    name: []u8,
    /// Structured extras for the result's `details` field, as a complete JSON
    /// object, or null to omit it. See `tools.Output.details_json`.
    details_json: ?[]u8,
    /// An image the tool wants the model to see. Becomes a second content block
    /// on the result. Null for every tool but the ones whose job is pixels.
    image: ?ai.ImageBlock,
    /// Whether the call failed — the result's `isError`.
    failed: bool,

    pub fn deinit(self: *ToolResult, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id);
        gpa.free(self.content);
        gpa.free(self.name);
        if (self.details_json) |details| gpa.free(details);
        if (self.image) |*attached| attached.deinit(gpa);
        self.* = undefined;
    }
};

/// The narrow private callback interface ExecutorService uses to report
/// ToolCall lifecycle back to the agent. `on_finished` receives a const
/// pointer into the executor's already-allocated result slot — no
/// projection allocation.
pub const ToolCallObserver = struct {
    ptr: *anyopaque,
    on_started: *const fn (*anyopaque, ai.ToolCall) anyerror!void,
    on_finished: *const fn (*anyopaque, *const ToolResult) anyerror!void,
    approve_unsafe_bash: *const fn (*anyopaque, ai.ToolCall, []const u8) anyerror!bool,

    pub const noop: ToolCallObserver = .{
        .ptr = undefined,
        .on_started = noopStarted,
        .on_finished = noopFinished,
        .approve_unsafe_bash = noopApproveUnsafeBash,
    };

    pub fn noopStarted(_: *anyopaque, _: ai.ToolCall) anyerror!void {}
    pub fn noopFinished(_: *anyopaque, _: *const ToolResult) anyerror!void {}
    pub fn noopApproveUnsafeBash(_: *anyopaque, _: ai.ToolCall, _: []const u8) anyerror!bool {
        return true;
    }
};

pub const ExecutorService = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    bash_classifier_url: ?[]const u8 = null,
    background: ?BackgroundStart = null,

    pub const InitOptions = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        bash_classifier_url: ?[]const u8 = null,
        background: ?BackgroundStart = null,
    };

    pub fn init(options: InitOptions) ExecutorService {
        assert(options.cwd.len > 0);
        if (options.bash_classifier_url) |url| assert(url.len > 0);
        return .{
            .gpa = options.gpa,
            .io = options.io,
            .cwd = options.cwd,
            .bash_classifier_url = options.bash_classifier_url,
            .background = options.background,
        };
    }

    /// Run a batch of ToolCalls. For each call:
    ///   1. `observer.on_started(call)` fires.
    ///   2. The tool runs via the Tool registry.
    ///   3. A ToolResult is built with both channels.
    ///   4. `observer.on_finished(&result)` fires with a const pointer.
    /// Returns an owned slice. The agent moves the LLM-channel fields into
    /// history via `Agent.takeToolResults` and frees the rest.
    pub fn runAll(
        self: *ExecutorService,
        calls: []const ai.ToolCall,
        observer: ToolCallObserver,
    ) ![]ToolResult {
        const results = try self.gpa.alloc(ToolResult, calls.len);
        var initialized: usize = 0;
        errdefer {
            for (results[0..initialized]) |*r| r.deinit(self.gpa);
            self.gpa.free(results);
        }
        for (calls, 0..) |call, i| {
            try observer.on_started(observer.ptr, call);
            if (try self.shouldRejectUnsafeBash(call, observer)) {
                results[i] = try self.runRejected(call);
            } else {
                results[i] = try self.runOne(call);
            }
            initialized = i + 1;
            try observer.on_finished(observer.ptr, &results[i]);
        }
        return results;
    }

    fn shouldRejectUnsafeBash(self: *ExecutorService, call: ai.ToolCall, observer: ToolCallObserver) !bool {
        const url = self.bash_classifier_url orelse return false;
        if (!std.mem.eql(u8, call.name, "bash")) return false;
        const command = bash_safety.commandFromArguments(self.gpa, call.arguments) catch return false;
        defer self.gpa.free(command);
        const verdict = bash_safety.classify(self.gpa, self.io, url, self.cwd, command);
        if (verdict != .unsafe) return false;
        const approved = try observer.approve_unsafe_bash(observer.ptr, call, command);
        return !approved;
    }

    fn runOne(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
        var output = self.produceOutput(call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return self.runFailure(call, err),
        };
        defer output.deinit(self.gpa);

        const call_id = try self.gpa.dupe(u8, call.call_id);
        errdefer self.gpa.free(call_id);
        const content = try formatLlmObservation(self.gpa, output);
        errdefer self.gpa.free(content);
        const name = try self.gpa.dupe(u8, call.name);
        errdefer self.gpa.free(name);
        const details: ?[]u8 = if (output.details_json) |json| try self.gpa.dupe(u8, json) else null;
        errdefer if (details) |json| self.gpa.free(json);
        // Moved out of `output` rather than copied: the bytes can be megabytes and
        // `output.deinit` would otherwise free them behind us.
        const attached = output.image;
        output.image = null;
        return .{
            .call_id = call_id,
            .content = content,
            .name = name,
            .details_json = details,
            .image = attached,
            .failed = output.code != 0,
        };
    }

    /// A tool that failed to execute at all (spawn failure, cancellation aside).
    /// Reported as a failed result rather than an error, so one broken call does
    /// not abort the batch.
    fn runFailure(self: *ExecutorService, call: ai.ToolCall, err: anyerror) !ToolResult {
        const call_id = try self.gpa.dupe(u8, call.call_id);
        errdefer self.gpa.free(call_id);
        const name = try self.gpa.dupe(u8, call.name);
        errdefer self.gpa.free(name);
        const content = try std.fmt.allocPrint(self.gpa, "tool '{s}' failed to execute: {s}", .{ call.name, @errorName(err) });
        return .{
            .call_id = call_id,
            .content = content,
            .name = name,
            .details_json = null,
            .image = null,
            .failed = true,
        };
    }

    /// A bash call the safety classifier flagged and the client declined.
    fn runRejected(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
        const message = "The tool call was rejected as unsafe. Try something else.";
        const call_id = try self.gpa.dupe(u8, call.call_id);
        errdefer self.gpa.free(call_id);
        const name = try self.gpa.dupe(u8, call.name);
        errdefer self.gpa.free(name);
        const content = try self.gpa.dupe(u8, message);
        return .{
            .call_id = call_id,
            .content = content,
            .name = name,
            .details_json = null,
            .image = null,
            .failed = true,
        };
    }

    /// Source the tool's `Output`, routing a `run_in_background` bash call to the
    /// `BackgroundManager` (which spawns the job and returns immediately) and
    /// everything else through the normal blocking tool registry.
    fn produceOutput(self: *ExecutorService, call: ai.ToolCall) tools.Error!tools.Output {
        if (self.background) |bg| {
            if (std.mem.eql(u8, call.name, "bash") and bash_tool.wantsBackground(self.gpa, call.arguments)) {
                return bash_tool.runBackground(self.gpa, self.io, self.cwd, call.arguments, bg.manager, bg.owner);
            }
        }
        return tools.run(self.gpa, self.io, self.cwd, call.name, call.arguments);
    }
};

/// The LLM-facing observation: stdout if non-empty, else stderr if
/// non-empty, else the literal "empty". When both are non-empty (typical
/// for bash commands writing to both) concatenate so we don't drop signal.
fn formatLlmObservation(gpa: std.mem.Allocator, result: tools.Output) ![]u8 {
    if (result.observation) |observation| return observation.render(gpa);
    if (result.stdout.len > 0 and result.stderr.len > 0) {
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ result.stdout, result.stderr });
    }
    if (result.stdout.len > 0) return gpa.dupe(u8, result.stdout);
    if (result.stderr.len > 0) return gpa.dupe(u8, result.stderr);
    return gpa.dupe(u8, "empty");
}

test "ExecutorService runs bash and returns its observation" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const calls = [_]ai.ToolCall{
        .{
            .call_id = try gpa.dupe(u8, "call_0"),
            .name = try gpa.dupe(u8, "bash"),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf hello\",\"reason\":\"Print hello\"}"),
        },
    };
    defer for (calls) |c| {
        gpa.free(c.call_id);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    const results = try executor.runAll(&calls, ToolCallObserver.noop);
    defer {
        for (results) |*r| r.deinit(gpa);
        gpa.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("call_0", results[0].call_id);
    try std.testing.expectEqualStrings("hello", results[0].content);
    try std.testing.expect(!results[0].failed);
}

test "executor converts a tool execution error into a failed result" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });
    const call: ai.ToolCall = .{
        .call_id = try gpa.dupe(u8, "call_x"),
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rg foo\",\"reason\":\"search\"}"),
    };
    defer {
        gpa.free(call.call_id);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runFailure(call, error.Unexpected);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("call_x", result.call_id);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "failed to execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Unexpected") != null);
}

test "executor rejected bash result is failed and model-facing" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });
    const call: ai.ToolCall = .{
        .call_id = try gpa.dupe(u8, "call_reject"),
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rm -rf /\",\"reason\":\"clean\"}"),
    };
    defer {
        gpa.free(call.call_id);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runRejected(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("The tool call was rejected as unsafe. Try something else.", result.content);
}

test "executor dispatches write then edit, reporting content and details" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel = ".zig-cache/executor-tools-test";
    try std.Io.Dir.createDirPath(.cwd(), io, rel);
    const cwd = try std.fs.path.join(gpa, &.{ root, rel });
    defer gpa.free(cwd);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = io, .cwd = cwd });

    const calls = [_]ai.ToolCall{
        .{
            .call_id = try gpa.dupe(u8, "call_write"),
            .name = try gpa.dupe(u8, "write"),
            .arguments = try gpa.dupe(u8,
                \\{"path":"greet.txt","content":"hello\nworld\n"}
            ),
        },
        .{
            .call_id = try gpa.dupe(u8, "call_edit"),
            .name = try gpa.dupe(u8, "edit"),
            .arguments = try gpa.dupe(u8,
                \\{"path":"greet.txt","edits":[{"old_text":"world","new_text":"nova"}]}
            ),
        },
        .{
            .call_id = try gpa.dupe(u8, "call_bad_edit"),
            .name = try gpa.dupe(u8, "edit"),
            .arguments = try gpa.dupe(u8,
                \\{"path":"greet.txt","edits":[{"old_text":"absent","new_text":"x"}]}
            ),
        },
    };
    defer for (calls) |call| {
        gpa.free(call.call_id);
        gpa.free(call.name);
        gpa.free(call.arguments);
    };

    const results = try executor.runAll(&calls, ToolCallObserver.noop);
    defer {
        for (results) |*r| r.deinit(gpa);
        gpa.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);

    // write: succeeded, and carried its diff as structured details.
    try std.testing.expect(!results[0].failed);

    // edit: applied to what write just produced.
    try std.testing.expect(!results[1].failed);
    try std.testing.expect(std.mem.indexOf(u8, results[1].content, "1 replacement(s)") != null);

    // A failed edit is reported as failed with a corrective message, not a crash.
    try std.testing.expect(results[2].failed);
    try std.testing.expect(std.mem.indexOf(u8, results[2].content, "was not found") != null);

    // The file on disk reflects both successful calls and none of the failed one.
    const path = try std.fs.path.join(gpa, &.{ rel, "greet.txt" });
    defer gpa.free(path);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const content = try reader.interface.allocRemaining(gpa, .limited(4096));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hello\nnova\n", content);
}

test "executor reports an unknown tool without failing the batch" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "." });
    const calls = [_]ai.ToolCall{.{
        .call_id = try gpa.dupe(u8, "call_x"),
        .name = try gpa.dupe(u8, "no_such_tool"),
        .arguments = try gpa.dupe(u8, "{}"),
    }};
    defer for (calls) |call| {
        gpa.free(call.call_id);
        gpa.free(call.name);
        gpa.free(call.arguments);
    };

    const results = try executor.runAll(&calls, ToolCallObserver.noop);
    defer {
        for (results) |*r| r.deinit(gpa);
        gpa.free(results);
    }
    try std.testing.expect(results[0].failed);
    try std.testing.expect(std.mem.indexOf(u8, results[0].content, "unknown tool") != null);
}

test "an image a tool attached reaches the result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_rel = ".zig-cache/executor-image-test";
    try std.Io.Dir.createDirPath(.cwd(), io, dir_rel);
    {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_rel, .{});
        defer dir.close(io);
        var file = try dir.createFile(io, "shot.png", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "\x89PNG\r\n\x1a\n" ++ ("\x00" ** 24));
    }
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const cwd = try std.fs.path.join(gpa, &.{ root, dir_rel });
    defer gpa.free(cwd);

    const calls = [_]ai.ToolCall{.{
        .call_id = try gpa.dupe(u8, "call_0"),
        .name = try gpa.dupe(u8, "view_image"),
        .arguments = try gpa.dupe(u8, "{\"path\":\"shot.png\"}"),
    }};
    defer for (calls) |c| {
        gpa.free(c.call_id);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = io, .cwd = cwd });
    const results = try executor.runAll(&calls, ToolCallObserver.noop);
    defer {
        for (results) |*r| r.deinit(gpa);
        gpa.free(results);
    }
    const attached = results[0].image orelse return error.TestFailed;
    try std.testing.expectEqualStrings("image/png", attached.mime_type);
    try std.testing.expect(std.mem.indexOf(u8, results[0].content, "shot.png") != null);
    try std.testing.expect(!results[0].failed);
}
