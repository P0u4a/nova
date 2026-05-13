/// Intercept bash tool calls and route recognized custom-tool segments to
/// our in-process handlers. Anything else (or any pipeline starting with an
/// unrecognized segment) is handed back to bash so the model's existing
/// muscle memory keeps working.
const std = @import("std");

const bash = @import("../bash.zig");
const common = @import("common.zig");
const handlers = @import("handlers.zig");
const parse = @import("parse.zig");

const assert = std.debug.assert;

pub const Error = common.Error;

/// Try to execute `command` ourselves. Returns null when the command contains
/// shell features outside our subset; the caller should fall back to running
/// the full command through bash.
pub fn tryHandle(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
) Error!?bash.Result {
    assert(cwd.len > 0);
    if (command.len == 0) return null;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const tree = parse.parse(arena_state.allocator(), command) catch |err| switch (err) {
        parse.Error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (tree.pipelines.len == 0) return null;
    return try executeCommand(gpa, io, cwd, command, tree);
}

fn executeCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    tree: parse.Command,
) Error!bash.Result {
    var stdout_buffer: std.ArrayList(u8) = .empty;
    errdefer stdout_buffer.deinit(gpa);
    var stderr_buffer: std.ArrayList(u8) = .empty;
    errdefer stderr_buffer.deinit(gpa);

    var chain_code: u8 = 0;
    for (tree.pipelines, 0..) |pipeline, index| {
        if (index > 0 and !shouldRunNext(tree.separators[index - 1], chain_code)) continue;
        var pipeline_result = try executePipeline(gpa, io, cwd, command, pipeline);
        defer pipeline_result.deinit(gpa);
        try stdout_buffer.appendSlice(gpa, pipeline_result.stdout);
        try stderr_buffer.appendSlice(gpa, pipeline_result.stderr);
        chain_code = pipeline_result.code;
    }

    return .{
        .stdout = try stdout_buffer.toOwnedSlice(gpa),
        .stderr = try stderr_buffer.toOwnedSlice(gpa),
        .code = chain_code,
    };
}

fn shouldRunNext(separator: parse.Separator, previous_code: u8) bool {
    switch (separator) {
        .semicolon => return true,
        .and_and => return previous_code == 0,
        .or_or => return previous_code != 0,
    }
}

fn executePipeline(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    pipeline: parse.Pipeline,
) Error!bash.Result {
    assert(pipeline.simples.len >= 1);
    if (!canStartInProcess(pipeline.simples[0])) {
        const substring = command[pipeline.span_start..pipeline.span_end];
        return bash.run(gpa, io, cwd, substring) catch |err| return mapSpawnError(err);
    }

    var stdin_buffer: []u8 = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdin_buffer);
    var stderr_accumulated: std.ArrayList(u8) = .empty;
    errdefer stderr_accumulated.deinit(gpa);
    var last_code: u8 = 0;

    for (pipeline.simples) |simple| {
        if (!canStartInProcess(simple)) {
            const substring = command[simple.span_start..pipeline.span_end];
            return finishWithBash(gpa, io, cwd, substring, &stdin_buffer, &stderr_accumulated);
        }
        const stage = try executeSimple(gpa, io, cwd, simple, stdin_buffer);
        gpa.free(stdin_buffer);
        stdin_buffer = stage.stdout;
        try stderr_accumulated.appendSlice(gpa, stage.stderr);
        gpa.free(stage.stderr);
        last_code = stage.code;
    }

    return .{
        .stdout = stdin_buffer,
        .stderr = try stderr_accumulated.toOwnedSlice(gpa),
        .code = last_code,
    };
}

fn canStartInProcess(simple: parse.Simple) bool {
    if (!handlers.recognize(simple)) return false;
    var input_count: u32 = 0;
    var output_count: u32 = 0;
    for (simple.redirects) |redir| {
        switch (redir.kind) {
            .input => input_count += 1,
            .output => output_count += 1,
            // `>>` would need O_APPEND or read-modify-write; defer to bash.
            .append => return false,
        }
    }
    if (input_count > 1) return false;
    if (output_count > 1) return false;
    return true;
}

fn finishWithBash(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    substring: []const u8,
    stdin_buffer: *[]u8,
    stderr_accumulated: *std.ArrayList(u8),
) Error!bash.Result {
    const bash_result = bash.runWithStdin(gpa, io, cwd, substring, stdin_buffer.*) catch |err| return mapSpawnError(err);
    gpa.free(stdin_buffer.*);
    stdin_buffer.* = &[_]u8{};
    try stderr_accumulated.appendSlice(gpa, bash_result.stderr);
    gpa.free(bash_result.stderr);
    return .{
        .stdout = bash_result.stdout,
        .stderr = try stderr_accumulated.toOwnedSlice(gpa),
        .code = bash_result.code,
    };
}

const Stage = struct { stdout: []u8, stderr: []u8, code: u8 };

fn executeSimple(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    simple: parse.Simple,
    pipe_stdin: []const u8,
) Error!Stage {
    const stdin_for_handler = try applyInputRedirect(gpa, io, cwd, simple, pipe_stdin);
    defer if (stdin_for_handler.ptr != pipe_stdin.ptr) gpa.free(@constCast(stdin_for_handler));

    var output = try handlers.run(gpa, io, cwd, simple, stdin_for_handler);
    errdefer output.deinit(gpa);

    const stdout_after_redirect = try applyOutputRedirect(gpa, io, cwd, simple, output.stdout);
    if (stdout_after_redirect.ptr != output.stdout.ptr) {
        gpa.free(output.stdout);
    }
    return .{ .stdout = stdout_after_redirect, .stderr = output.stderr, .code = output.code };
}

fn applyInputRedirect(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    simple: parse.Simple,
    pipe_stdin: []const u8,
) Error![]const u8 {
    var redirect_target: ?[]const u8 = null;
    for (simple.redirects) |redir| {
        if (redir.kind == .input) redirect_target = redir.target;
    }
    const path = redirect_target orelse return pipe_stdin;
    const absolute = try joinPath(gpa, cwd, path);
    defer gpa.free(absolute);
    var file = std.Io.Dir.openFileAbsolute(io, absolute, .{}) catch |err| return mapFileError(err);
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    return file_reader.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return mapFileError(file_reader.err.?),
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.OutOfMemory,
    };
}

fn applyOutputRedirect(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    simple: parse.Simple,
    handler_stdout: []const u8,
) Error![]u8 {
    var redirect_target: ?parse.Redirect = null;
    for (simple.redirects) |redir| {
        if (redir.kind == .output) redirect_target = redir;
    }
    const redir = redirect_target orelse return gpa.dupe(u8, handler_stdout);
    assert(redir.kind == .output);
    const absolute = try joinPath(gpa, cwd, redir.target);
    defer gpa.free(absolute);
    var file = std.Io.Dir.createFileAbsolute(io, absolute, .{ .truncate = true }) catch |err| return mapFileError(err);
    defer file.close(io);
    file.writeStreamingAll(io, handler_stdout) catch |err| return mapFileError(err);
    return gpa.alloc(u8, 0);
}

fn joinPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ cwd, path });
}

fn mapFileError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
}

fn mapSpawnError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.Unexpected,
    };
}

test "tryHandle returns null for unsupported syntax" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    try std.testing.expectEqual(@as(?bash.Result, null), try tryHandle(gpa, std.testing.io, cwd, "echo $HOME"));
}

test "tryHandle routes read-file --help to the in-process handler" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = (try tryHandle(gpa, std.testing.io, cwd, "read-file --help")).?;
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "read-file") != null);
}

test "tryHandle hands the whole pipeline to bash when the head is unknown" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = (try tryHandle(gpa, std.testing.io, cwd, "printf hi")).?;
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("hi", result.stdout);
}
