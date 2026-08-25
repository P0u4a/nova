//! JSON-RPC server: the only interface to the agent.
//!
//! Commands arrive as JSON objects on stdin, one per line. Responses and events
//! leave as JSON objects on stdout, one per line. The wire contract follows Pi's
//! RPC mode, so a client written against `pi --mode rpc` works here.
//!
//! ## Framing
//!
//! Strict JSONL with LF as the only record delimiter. A trailing `\r` on input is
//! stripped, so CRLF clients work, but `U+2028`/`U+2029` are *not* delimiters —
//! they are legal inside JSON strings, and splitting on them corrupts records.
//!
//! ## Threads
//!
//! The reader loop owns stdin and runs on the main thread. A turn runs on its own
//! thread so `abort` and `steer` are answerable while the model streams. Both
//! threads write to stdout, so every write goes through `Output`, which holds a
//! mutex for the duration of one line — that is what keeps records from
//! interleaving.
//!
//! ## Events
//!
//! `Agent.Event` is coarser than the wire protocol: the agent reports deltas but
//! not content-block boundaries. `EventWriter` synthesises them, tracking the
//! current block and its `contentIndex` and closing one block before opening the
//! next, which is what lets a client assemble a partial message from the stream.

const std = @import("std");
const logger = @import("logger");

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const config_mod = @import("config.zig");
const runtime_mod = @import("runtime.zig");
const tools_mod = @import("tools.zig");

const assert = std.debug.assert;

/// Cap on one command record. Prompts can be large (pasted files), but a client
/// that never sends a newline must not be able to exhaust memory. Exceeding it
/// discards that one record, not the session.
const line_bytes_max: usize = 8 * 1024 * 1024;

/// Serialized stdout. Both the reader thread (responses) and the turn thread
/// (events) write here, so the mutex is held across a whole line — a half-written
/// record would break the client's parser.
pub const Output = struct {
    mutex: std.atomic.Mutex = .unlocked,
    sink: Sink,

    /// Where records go. `stream` is the real one; `buffer` lets a test observe
    /// the exact bytes a client would receive, which is the only way to check the
    /// wire format without a live provider.
    pub const Sink = union(enum) {
        stream: struct { file: std.Io.File, io: std.Io },
        buffer: struct { gpa: std.mem.Allocator, lines: *std.ArrayList(u8) },
    };

    pub fn toStream(io: std.Io, file: std.Io.File) Output {
        return .{ .sink = .{ .stream = .{ .file = file, .io = io } } };
    }

    pub fn toBuffer(gpa: std.mem.Allocator, lines: *std.ArrayList(u8)) Output {
        return .{ .sink = .{ .buffer = .{ .gpa = gpa, .lines = lines } } };
    }

    /// Write one complete JSON line. `body` must be a complete JSON object with
    /// no trailing newline.
    pub fn writeLine(self: *Output, body: []const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        switch (self.sink) {
            .stream => |stream| {
                stream.file.writeStreamingAll(stream.io, body) catch return;
                stream.file.writeStreamingAll(stream.io, "\n") catch return;
            },
            .buffer => |sink| {
                sink.lines.appendSlice(sink.gpa, body) catch return;
                sink.lines.append(sink.gpa, '\n') catch return;
            },
        }
    }
};

/// Spin-with-yield acquire; `std.atomic.Mutex` has no blocking `lock`, and the
/// critical section is one write.
fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

/// Split a byte stream into JSONL records. LF only; a trailing CR is stripped so
/// a CRLF client is accepted without treating CR as a delimiter.
pub const LineReader = struct {
    gpa: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    /// Where the record returned by `next` ends, so `commit` can drop it. Zero
    /// when nothing is pending.
    pending_start: usize = 0,
    /// Longest record accepted. A field rather than a constant so tests can drive
    /// the discard path without allocating megabytes.
    limit: usize = line_bytes_max,
    /// Length of the unterminated bytes at the end of `buffer` — the record still
    /// in flight. The size cap applies to this, not to the whole buffer, so a
    /// burst of small commands is never mistaken for one oversized one.
    tail_len: usize = 0,
    /// True while the record in flight has already been given up on: bytes are
    /// discarded until its terminating newline arrives.
    draining: bool = false,
    /// Set when a record is dropped, cleared by `takeOverflow`, so the caller
    /// reports one error per oversized record rather than one per chunk.
    overflowed: bool = false,

    pub fn deinit(self: *LineReader) void {
        self.buffer.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append raw input.
    ///
    /// A record longer than `line_bytes_max` is discarded rather than ending the
    /// session: the bytes up to and including its newline are dropped, the caller
    /// is told once via `takeOverflow`, and parsing resumes with the next record.
    /// A client that sends one bad frame — or none at all, just a stream with no
    /// newline in it — should not lose the commands that follow.
    pub fn push(self: *LineReader, bytes: []const u8) !void {
        assert(self.pending_start == 0); // `commit` the borrowed record first.
        var rest = bytes;
        while (rest.len > 0) {
            if (self.draining) {
                const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse return;
                rest = rest[newline + 1 ..];
                self.draining = false;
                continue;
            }

            const newline = std.mem.indexOfScalar(u8, rest, '\n');
            // Take the record including its newline, or the whole chunk when the
            // record has not ended yet. The cap is measured on the content, so a
            // record exactly at the limit is not failed by its own delimiter.
            const content = newline orelse rest.len;
            const take = if (newline) |at| at + 1 else rest.len;
            if (self.tail_len + content > self.limit) {
                self.dropTail();
                self.overflowed = true;
                if (newline) |at| {
                    rest = rest[at + 1 ..];
                    continue;
                }
                self.draining = true;
                return;
            }

            try self.buffer.appendSlice(self.gpa, rest[0..take]);
            if (newline == null) {
                self.tail_len += take;
                return;
            }
            self.tail_len = 0;
            rest = rest[take..];
        }
    }

    /// Whether a record has been dropped since the last call. Clears the flag.
    pub fn takeOverflow(self: *LineReader) bool {
        defer self.overflowed = false;
        return self.overflowed;
    }

    /// Forget the partial record at the end of the buffer, keeping any complete
    /// records still waiting in front of it.
    fn dropTail(self: *LineReader) void {
        assert(self.tail_len <= self.buffer.items.len);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - self.tail_len);
        self.tail_len = 0;
    }

    /// The next complete record, or null when none is buffered yet. The returned
    /// slice is valid until the next `push`/`next`.
    pub fn next(self: *LineReader) ?[]const u8 {
        const end = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse return null;
        const line = self.buffer.items[0..end];
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        self.pending_start = end + 1;
        return trimmed;
    }

    /// Drop the record `next` just returned. Separate from `next` so the caller
    /// can borrow the slice while parsing.
    pub fn commit(self: *LineReader) void {
        if (self.pending_start == 0) return;
        const rest = self.buffer.items.len - self.pending_start;
        std.mem.copyForwards(u8, self.buffer.items[0..rest], self.buffer.items[self.pending_start..]);
        self.buffer.shrinkRetainingCapacity(rest);
        self.pending_start = 0;
    }
};

/// Which content block the assistant is currently streaming, so boundaries can be
/// synthesised from the agent's boundary-free deltas.
const Block = union(enum) {
    none,
    text,
    thinking,
    /// Tool call, keyed by the tool index the agent reports in its deltas.
    tool: u32,
};

/// Translates `Agent.Event` into the wire event stream.
pub const EventWriter = struct {
    gpa: std.mem.Allocator,
    out: *Output,
    /// Cleared by `abort`; makes the next event abort the turn (the listener
    /// returning an error is how `Agent.run` unwinds).
    cancel: *std.atomic.Value(bool),

    block: Block = .none,
    content_index: u32 = 0,
    /// Accumulated text of the block in flight, so `*_end` can carry the complete
    /// content the way the contract specifies.
    accumulated: std.ArrayList(u8) = .empty,
    /// Name of the tool whose call is streaming, for `toolcall_end`.
    tool_name: std.ArrayList(u8) = .empty,
    tool_call_id: std.ArrayList(u8) = .empty,
    /// The agent whose history `turn_end` and `agent_end` report. Read only at
    /// event time, on the turn thread that owns it.
    agent: *agent_mod.Agent,
    /// Which turn of this run is streaming, counting from zero.
    turn_index: u32 = 0,
    /// Length of history when the current turn began, so `turn_end` can report
    /// just this turn's messages rather than the whole conversation.
    turn_start: usize = 0,

    pub fn deinit(self: *EventWriter) void {
        self.accumulated.deinit(self.gpa);
        self.tool_name.deinit(self.gpa);
        self.tool_call_id.deinit(self.gpa);
        self.* = undefined;
    }

    /// `Agent.Listener` entry point. Returns `error.TurnCancelled` once an abort
    /// has been requested, which is how the turn is stopped.
    pub fn onEvent(context: *anyopaque, event: agent_mod.Agent.Event) anyerror!void {
        const self: *EventWriter = @ptrCast(@alignCast(context));
        var owned = event;
        defer owned.deinit(self.gpa);
        if (self.cancel.load(.acquire)) return error.TurnCancelled;
        try self.handle(owned);
    }

    fn handle(self: *EventWriter, event: agent_mod.Agent.Event) !void {
        switch (event) {
            .turn_started => {
                self.turn_start = self.agent.messages().len;
                try self.emitSimple("turn_start");
            },
            .response_delta => |text| try self.streamDelta(.text, text),
            .thinking_delta => |text| try self.streamDelta(.thinking, text),
            .tool_delta => |tool| try self.toolDelta(tool),
            .delta_end => try self.closeBlock(),
            .tool_call_started => |call| try self.toolExecutionStart(call),
            .tool_call_finished => |call| try self.toolExecutionEnd(call),
            .tool_batch_finished => {},
            .queued_messages_flushed => {},
            .turn_finished => {
                try self.closeBlock();
                try self.turnEnd();
                self.turn_index += 1;
            },
            .turn_failed => |message| try self.turnFailed(message),
            .history_compacted => |compacted| {
                // Compaction rewrites the prefix, so the anchor taken at
                // `turn_start` no longer points where it did. It runs before the
                // turn's own messages exist, so the new length is the new anchor.
                self.turn_start = self.agent.messages().len;
                try self.compactionEnd(compacted);
            },
        }
    }

    /// Open `kind` if it is not already open (closing whatever was), then stream
    /// one delta into it.
    fn streamDelta(self: *EventWriter, kind: Block, text: []const u8) !void {
        const same = switch (kind) {
            .text => self.block == .text,
            .thinking => self.block == .thinking,
            else => false,
        };
        if (!same) {
            try self.closeBlock();
            self.block = kind;
            try self.emitBlockStart(switch (kind) {
                .text => "text_start",
                .thinking => "thinking_start",
                else => unreachable,
            }, null);
        }
        try self.accumulated.appendSlice(self.gpa, text);

        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":");
        try std.json.Stringify.value(if (kind == .text) "text_delta" else "thinking_delta", .{}, w);
        try w.print(",\"contentIndex\":{d},\"delta\":", .{self.content_index});
        try std.json.Stringify.value(text, .{}, w);
        try w.writeAll("}}");
        self.out.writeLine(line.written());
    }

    fn toolDelta(self: *EventWriter, tool: ai.ToolDelta) !void {
        const same = switch (self.block) {
            .tool => |index| index == tool.index,
            else => false,
        };
        if (!same) {
            try self.closeBlock();
            self.block = .{ .tool = tool.index };
            self.tool_name.clearRetainingCapacity();
            try self.tool_name.appendSlice(self.gpa, tool.name);
            try self.emitBlockStart("toolcall_start", tool.name);
        }
        try self.accumulated.appendSlice(self.gpa, tool.arguments);

        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_delta\"");
        try w.print(",\"contentIndex\":{d},\"delta\":", .{self.content_index});
        try std.json.Stringify.value(tool.arguments, .{}, w);
        try w.writeAll("}}");
        self.out.writeLine(line.written());
    }

    fn emitBlockStart(self: *EventWriter, kind: []const u8, tool_name: ?[]const u8) !void {
        self.accumulated.clearRetainingCapacity();
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":");
        try std.json.Stringify.value(kind, .{}, w);
        try w.print(",\"contentIndex\":{d}", .{self.content_index});
        if (tool_name) |name| {
            try w.writeAll(",\"toolName\":");
            try std.json.Stringify.value(name, .{}, w);
        }
        try w.writeAll("}}");
        self.out.writeLine(line.written());
    }

    /// Close the block in flight, emitting its `*_end` with the complete content,
    /// and advance `contentIndex` so the next block gets a fresh one.
    fn closeBlock(self: *EventWriter) !void {
        const kind: []const u8 = switch (self.block) {
            .none => return,
            .text => "text_end",
            .thinking => "thinking_end",
            .tool => "toolcall_end",
        };
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":");
        try std.json.Stringify.value(kind, .{}, w);
        try w.print(",\"contentIndex\":{d}", .{self.content_index});
        switch (self.block) {
            .tool => {
                // The contract wants the assembled call here, not just the tail.
                try w.writeAll(",\"toolCall\":{\"name\":");
                try std.json.Stringify.value(self.tool_name.items, .{}, w);
                try w.writeAll(",\"arguments\":");
                try std.json.Stringify.value(self.accumulated.items, .{}, w);
                try w.writeAll("}");
            },
            .text, .thinking => {
                try w.writeAll(",\"content\":");
                try std.json.Stringify.value(self.accumulated.items, .{}, w);
            },
            .none => unreachable,
        }
        try w.writeAll("}}");
        self.out.writeLine(line.written());

        self.block = .none;
        self.accumulated.clearRetainingCapacity();
        self.content_index += 1;
    }

    fn toolExecutionStart(self: *EventWriter, call: agent_mod.Agent.Event.ToolCallStarted) !void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"tool_execution_start\",\"toolCallId\":");
        try std.json.Stringify.value(call.call_id, .{}, w);
        try w.writeAll(",\"toolName\":");
        try std.json.Stringify.value(call.name, .{}, w);
        try w.writeAll(",\"args\":");
        writeRawJsonOrString(w, call.arguments) catch return error.OutOfMemory;
        try w.writeAll("}");
        self.out.writeLine(line.written());
    }

    fn toolExecutionEnd(self: *EventWriter, call: agent_mod.Agent.Event.ToolCallFinished) !void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"tool_execution_end\",\"toolCallId\":");
        try std.json.Stringify.value(call.call_id, .{}, w);
        try w.writeAll(",\"toolName\":");
        try std.json.Stringify.value(call.name, .{}, w);
        try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(call.content, .{}, w);
        try w.writeByte('}');
        // A second content block when the tool attached an image, in the same
        // shape the `prompt` command accepts them in — so a client can round-trip
        // one straight back.
        if (call.image) |attached| {
            try w.writeAll(",{\"type\":\"image\",\"mimeType\":");
            try std.json.Stringify.value(attached.mime_type, .{}, w);
            try w.writeAll(",\"data\":");
            try std.json.Stringify.value(attached.data_base64, .{}, w);
            try w.writeByte('}');
        }
        try w.writeByte(']');
        if (call.details_json) |details| {
            try w.writeAll(",\"details\":");
            try w.writeAll(details);
        }
        try w.writeAll("},\"isError\":");
        try w.writeAll(if (call.failed) "true" else "false");
        try w.writeAll("}");
        self.out.writeLine(line.written());
    }

    /// `turn_end`, carrying the assistant message this turn produced and the
    /// results of the tools it called.
    ///
    /// Read back out of history rather than reassembled from the deltas already
    /// emitted, so this cannot drift from what `get_messages` reports. A client
    /// that only wants the answer never has to accumulate deltas or make a
    /// follow-up request — which would race the next queued turn.
    fn turnEnd(self: *EventWriter) !void {
        const history = self.agent.messages();
        assert(self.turn_start <= history.len);
        const produced = history[self.turn_start..];

        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.print("{{\"type\":\"turn_end\",\"turnIndex\":{d}", .{self.turn_index});

        for (produced) |message| {
            if (message.role != .assistant) continue;
            try w.writeAll(",\"message\":");
            try writeMessage(w, message);
            break;
        }

        try w.writeAll(",\"toolResults\":[");
        var written: u32 = 0;
        for (produced) |message| {
            if (message.role != .tool) continue;
            if (written > 0) try w.writeByte(',');
            try writeMessage(w, message);
            written += 1;
        }
        try w.writeAll("]}");
        self.out.writeLine(line.written());
    }

    /// `agent_end`, carrying the whole conversation as it now stands.
    fn agentEnd(self: *EventWriter) !void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"agent_end\",\"messages\":[");
        var written: u32 = 0;
        for (self.agent.messages()) |message| {
            if (message.role == .system) continue;
            if (written > 0) try w.writeByte(',');
            try writeMessage(w, message);
            written += 1;
        }
        try w.writeAll("]}");
        self.out.writeLine(line.written());
    }

    fn turnFailed(self: *EventWriter, message: []const u8) !void {
        try self.closeBlock();
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(message, .{}, w);
        try w.writeAll("}],\"stopReason\":\"error\"}}");
        self.out.writeLine(line.written());
    }

    fn compactionEnd(self: *EventWriter, compacted: agent_mod.Agent.Event.HistoryCompacted) !void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.print(
            "{{\"type\":\"compaction_end\",\"tokensBefore\":{d},\"tokensAfter\":{d}}}",
            .{ compacted.tokens_before, compacted.tokens_after },
        );
        self.out.writeLine(line.written());
    }

    fn emitSimple(self: *EventWriter, kind: []const u8) !void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        try w.writeAll("{\"type\":");
        try std.json.Stringify.value(kind, .{}, w);
        try w.writeAll("}");
        self.out.writeLine(line.written());
    }
};

/// Emit `raw` as JSON if it parses as an object, else as a JSON string. Tool
/// arguments arrive as provider-supplied text that is *usually* an object but can
/// be a truncated fragment; a client should never receive malformed JSON.
fn writeRawJsonOrString(w: *std.Io.Writer, raw: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) {
        // Validate before passing through; `parseFromSlice` needs an allocator, so
        // use a scratch one bounded by the fragment itself.
        var buffer: [64 * 1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        if (std.json.parseFromSlice(std.json.Value, fba.allocator(), trimmed, .{})) |parsed| {
            defer parsed.deinit();
            try w.writeAll(trimmed);
            return;
        } else |_| {}
    }
    try std.json.Stringify.value(raw, .{}, w);
}

/// How a prompt sent while the agent is streaming should be handled.
const StreamingBehavior = enum { steer, follow_up };

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *runtime_mod.AgentRuntime,
    /// Where a new session is recorded as living — the project root, so every
    /// session for this project groups together.
    session_dir: []const u8,
    config: config_mod.Config,
    out: Output,
    cancel: std.atomic.Value(bool) = .init(false),
    /// The turn thread, when one is running.
    turn: ?std.Thread = null,
    /// Set by the turn thread as it finishes so the reader can join without
    /// blocking on a turn that is still streaming.
    turn_done: std.atomic.Value(bool) = .init(false),

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_mod.AgentRuntime,
        session_dir: []const u8,
        config: config_mod.Config,
    ) Server {
        assert(session_dir.len > 0);
        return .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .session_dir = session_dir,
            .config = config,
            .out = Output.toStream(io, std.Io.File.stdout()),
        };
    }

    fn agent(self: *Server) *agent_mod.Agent {
        return &self.runtime.agent;
    }

    fn streaming(self: *Server) bool {
        return self.turn != null and !self.turn_done.load(.acquire);
    }

    /// Join a finished turn thread. Called before starting another one and at
    /// shutdown, so no worker outlives the server.
    fn reapTurn(self: *Server) void {
        if (self.turn) |thread| {
            if (!self.turn_done.load(.acquire)) return;
            thread.join();
            self.turn = null;
            self.turn_done.store(false, .release);
        }
    }

    fn joinTurn(self: *Server) void {
        if (self.turn) |thread| {
            thread.join();
            self.turn = null;
            self.turn_done.store(false, .release);
        }
    }

    pub fn deinit(self: *Server) void {
        self.cancel.store(true, .release);
        self.joinTurn();
        self.* = undefined;
    }

    /// Read commands until stdin closes.
    pub fn run(self: *Server) !void {
        var reader: LineReader = .{ .gpa = self.gpa };
        defer reader.deinit();

        var stdin = std.Io.File.stdin();
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            var chunks = [_][]u8{&chunk};
            const read = stdin.readStreaming(self.io, &chunks) catch break;
            if (read == 0) break;
            try reader.push(chunk[0..read]);
            // Report the discard before the records that followed it, since that
            // is the order the client sent them in.
            if (reader.takeOverflow()) {
                self.respondError(null, "parse", "Command exceeded the maximum line length and was discarded");
            }
            while (reader.next()) |line| {
                // Copy out: dispatch may append to the same buffer via `commit`.
                const owned = try self.gpa.dupe(u8, line);
                defer self.gpa.free(owned);
                reader.commit();
                if (std.mem.trim(u8, owned, " \t").len == 0) continue;
                self.dispatch(owned);
            }
        }
        // stdin closed. Let a turn in flight run to completion rather than
        // cancelling it: a one-shot invocation (`echo '{...}' | nova`) hits EOF
        // immediately after the prompt is accepted, and cancelling there would
        // discard the whole answer.
        self.joinTurn();
    }

    fn dispatch(self: *Server, line: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, line, .{}) catch {
            self.respondError(null, "parse", "Failed to parse command as JSON");
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.respondError(null, "parse", "Command must be a JSON object");
            return;
        }
        const object = parsed.value.object;
        const id = stringField(object, "id");
        const kind = stringField(object, "type") orelse {
            self.respondError(id, "parse", "Command is missing `type`");
            return;
        };

        self.reapTurn();

        if (std.mem.eql(u8, kind, "prompt")) {
            self.handlePrompt(id, object);
        } else if (std.mem.eql(u8, kind, "steer")) {
            self.handleQueue(id, "steer", object, .steer);
        } else if (std.mem.eql(u8, kind, "follow_up")) {
            self.handleQueue(id, "follow_up", object, .follow_up);
        } else if (std.mem.eql(u8, kind, "abort")) {
            self.handleAbort(id);
        } else if (std.mem.eql(u8, kind, "get_state")) {
            self.handleGetState(id);
        } else if (std.mem.eql(u8, kind, "get_messages")) {
            self.handleGetMessages(id);
        } else if (std.mem.eql(u8, kind, "get_last_assistant_text")) {
            self.handleGetLastAssistantText(id);
        } else if (std.mem.eql(u8, kind, "new_session")) {
            self.handleNewSession(id);
        } else if (std.mem.eql(u8, kind, "switch_session")) {
            self.handleSwitchSession(id, object);
        } else if (std.mem.eql(u8, kind, "set_model")) {
            self.handleSetModel(id, object);
        } else if (std.mem.eql(u8, kind, "get_available_models")) {
            self.handleGetAvailableModels(id);
        } else if (std.mem.eql(u8, kind, "get_commands")) {
            self.respondData(id, "get_commands", "{\"commands\":[]}");
        } else {
            var buffer: [160]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "Unknown command: {s}", .{kind}) catch "Unknown command";
            self.respondError(id, kind, message);
        }
    }

    fn handlePrompt(self: *Server, id: ?[]const u8, object: std.json.ObjectMap) void {
        const message = stringField(object, "message") orelse {
            self.respondError(id, "prompt", "`message` is required");
            return;
        };
        if (message.len == 0) {
            self.respondError(id, "prompt", "`message` must not be empty");
            return;
        }
        const images = switch (parseImages(self.gpa, object)) {
            .invalid => |reason| {
                self.respondError(id, "prompt", reason);
                return;
            },
            .images => |images| images,
        };
        // Ownership moves to whatever accepts the message below; only the paths
        // that reject it have to clean up.
        var handed_off = false;
        defer if (!handed_off) agent_mod.freeImages(self.gpa, images);

        if (self.streaming()) {
            const behavior = stringField(object, "streamingBehavior") orelse {
                self.respondError(id, "prompt", "Agent is streaming; specify streamingBehavior (\"steer\" or \"followUp\")");
                return;
            };
            if (std.mem.eql(u8, behavior, "steer")) {
                self.queueMessage(id, "prompt", message, images, .steer);
            } else if (std.mem.eql(u8, behavior, "followUp")) {
                self.queueMessage(id, "prompt", message, images, .follow_up);
            } else {
                self.respondError(id, "prompt", "streamingBehavior must be \"steer\" or \"followUp\"");
                return;
            }
            handed_off = true;
            return;
        }

        self.startTurn(message, images) catch |err| {
            var buffer: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "Could not start turn: {s}", .{@errorName(err)}) catch "Could not start turn";
            self.respondError(id, "prompt", text);
            return;
        };
        handed_off = true;
        self.respondOk(id, "prompt");
    }

    fn handleQueue(
        self: *Server,
        id: ?[]const u8,
        command: []const u8,
        object: std.json.ObjectMap,
        behavior: StreamingBehavior,
    ) void {
        const message = stringField(object, "message") orelse {
            self.respondError(id, command, "`message` is required");
            return;
        };
        if (message.len == 0) {
            self.respondError(id, command, "`message` must not be empty");
            return;
        }
        const images = switch (parseImages(self.gpa, object)) {
            .invalid => |reason| {
                self.respondError(id, command, reason);
                return;
            },
            .images => |images| images,
        };
        self.queueMessage(id, command, message, images, behavior);
    }

    /// Queue `message` for delivery. Takes ownership of `images`.
    fn queueMessage(
        self: *Server,
        id: ?[]const u8,
        command: []const u8,
        message: []const u8,
        images: []ai.ImageBlock,
        behavior: StreamingBehavior,
    ) void {
        defer agent_mod.freeImages(self.gpa, images);
        const input: agent_mod.Agent.QueuedInput = .{
            .text = message,
            .images = images,
            .steer = behavior == .steer,
        };
        self.agent().enqueue(input) catch |err| {
            var buffer: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "Could not queue message: {s}", .{@errorName(err)}) catch "Could not queue message";
            self.respondError(id, command, text);
            return;
        };
        self.respondOk(id, command);
        self.emitQueueUpdate();

        // A message queued while nothing is running would otherwise sit there:
        // start a turn to deliver it.
        if (!self.streaming()) {
            self.startQueuedTurn() catch {};
        }
    }

    fn handleAbort(self: *Server, id: ?[]const u8) void {
        self.cancel.store(true, .release);
        self.joinTurn();
        self.agent().clearQueue();
        self.cancel.store(false, .release);
        self.respondOk(id, "abort");
        self.emitQueueUpdate();
    }

    fn handleGetState(self: *Server, id: ?[]const u8) void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        w.writeAll("{\"isStreaming\":") catch return;
        w.writeAll(if (self.streaming()) "true" else "false") catch return;
        w.writeAll(",\"model\":") catch return;
        if (self.config.model) |model| {
            w.writeAll("{\"id\":") catch return;
            std.json.Stringify.value(model.id, .{}, w) catch return;
            w.writeAll("}") catch return;
        } else {
            w.writeAll("null") catch return;
        }
        w.print(",\"messageCount\":{d}", .{self.agent().messages().len}) catch return;
        w.print(",\"pendingMessageCount\":{d}", .{self.agent().queuedCount()}) catch return;
        w.writeAll(",\"sessionId\":") catch return;
        std.json.Stringify.value(self.runtime.session_writer.session.id.slice(), .{}, w) catch return;
        w.writeAll("}") catch return;
        self.respondData(id, "get_state", line.written());
    }

    fn handleGetMessages(self: *Server, id: ?[]const u8) void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        w.writeAll("{\"messages\":[") catch return;
        var written: usize = 0;
        for (self.agent().messages()) |message| {
            if (message.role == .system) continue;
            if (written > 0) w.writeByte(',') catch return;
            writeMessage(w, message) catch return;
            written += 1;
        }
        w.writeAll("]}") catch return;
        self.respondData(id, "get_messages", line.written());
    }

    fn handleGetLastAssistantText(self: *Server, id: ?[]const u8) void {
        var last: ?[]const u8 = null;
        for (self.agent().messages()) |message| {
            if (message.role != .assistant) continue;
            const text = message.text();
            if (text.len > 0) last = text;
        }
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        w.writeAll("{\"text\":") catch return;
        if (last) |text| {
            std.json.Stringify.value(text, .{}, w) catch return;
        } else {
            w.writeAll("null") catch return;
        }
        w.writeAll("}") catch return;
        self.respondData(id, "get_last_assistant_text", line.written());
    }

    /// Start a fresh conversation in a new session, keeping the client, the
    /// skills and the system prompt — only the transcript resets.
    fn handleNewSession(self: *Server, id: ?[]const u8) void {
        if (self.streaming()) {
            self.respondError(id, "new_session", "Agent is streaming; abort first");
            return;
        }
        self.agent().clearQueue();
        self.runtime.switchSession(self.session_dir, null) catch |err| {
            var buffer: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "Could not start a session: {s}", .{@errorName(err)}) catch "Could not start a session";
            self.respondError(id, "new_session", text);
            return;
        };
        self.respondData(id, "new_session", "{\"cancelled\":false}");
        self.emitQueueUpdate();
    }

    /// Resume an existing session by id.
    ///
    /// Pi addresses sessions by file path; Nova keeps every session as rows in
    /// one database, so `sessionId` is the address here. That is a deliberate
    /// divergence — there is no path to give.
    fn handleSwitchSession(self: *Server, id: ?[]const u8, object: std.json.ObjectMap) void {
        if (self.streaming()) {
            self.respondError(id, "switch_session", "Agent is streaming; abort first");
            return;
        }
        const session_id = stringField(object, "sessionId") orelse stringField(object, "sessionPath") orelse {
            self.respondError(id, "switch_session", "`sessionId` is required");
            return;
        };
        if (session_id.len == 0) {
            self.respondError(id, "switch_session", "`sessionId` must not be empty");
            return;
        }
        self.agent().clearQueue();
        self.runtime.switchSession(self.session_dir, session_id) catch |err| {
            var buffer: [200]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "Could not switch session: {s}", .{@errorName(err)}) catch "Could not switch session";
            self.respondError(id, "switch_session", text);
            return;
        };
        self.respondData(id, "switch_session", "{\"cancelled\":false}");
        self.emitQueueUpdate();
    }

    fn handleSetModel(self: *Server, id: ?[]const u8, object: std.json.ObjectMap) void {
        if (self.streaming()) {
            self.respondError(id, "set_model", "Agent is streaming; abort first");
            return;
        }
        const provider_name = stringField(object, "provider") orelse {
            self.respondError(id, "set_model", "`provider` is required");
            return;
        };
        const model_id = stringField(object, "modelId") orelse {
            self.respondError(id, "set_model", "`modelId` is required");
            return;
        };
        if (model_id.len == 0) {
            self.respondError(id, "set_model", "`modelId` must not be empty");
            return;
        }
        const provider = config_mod.providerFromName(provider_name) orelse {
            var buffer: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "Unknown provider: {s}", .{provider_name}) catch "Unknown provider";
            self.respondError(id, "set_model", text);
            return;
        };

        self.runtime.setModel(&self.config, provider, model_id) catch |err| {
            var buffer: [200]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "Could not select that model: {s}", .{@errorName(err)}) catch "Could not select that model";
            self.respondError(id, "set_model", text);
            return;
        };

        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        writeModel(&line.writer, provider, model_id) catch return;
        self.respondData(id, "set_model", line.written());
    }

    /// Every model the config names, across providers. This is what the config
    /// declares, not what a provider would report — Nova never queries a
    /// provider's catalogue.
    fn handleGetAvailableModels(self: *Server, id: ?[]const u8) void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        w.writeAll("{\"models\":[") catch return;
        var written: u32 = 0;
        for (self.config.providers) |provider| {
            for (provider.models) |model| {
                if (written > 0) w.writeByte(',') catch return;
                writeModel(w, provider.provider, model.id) catch return;
                written += 1;
            }
        }
        w.writeAll("]}") catch return;
        self.respondData(id, "get_available_models", line.written());
    }

    const TurnJob = struct {
        server: *Server,
        prompt: ?[]u8,
        /// Images attached to `prompt`, owned by the job and freed with it.
        images: []ai.ImageBlock,
        drain_queue: bool,
    };

    fn startTurn(self: *Server, message: []const u8, images: []ai.ImageBlock) !void {
        const owned = try self.gpa.dupe(u8, message);
        errdefer self.gpa.free(owned);
        try self.spawnTurn(owned, images, false);
    }

    fn startQueuedTurn(self: *Server) !void {
        try self.spawnTurn(null, &.{}, true);
    }

    fn spawnTurn(self: *Server, prompt: ?[]u8, images: []ai.ImageBlock, drain_queue: bool) !void {
        assert(self.turn == null);
        const job = try self.gpa.create(TurnJob);
        errdefer self.gpa.destroy(job);
        job.* = .{ .server = self, .prompt = prompt, .images = images, .drain_queue = drain_queue };
        self.cancel.store(false, .release);
        self.turn_done.store(false, .release);
        self.turn = try std.Thread.spawn(.{}, runTurn, .{job});
    }

    fn runTurn(job: *TurnJob) void {
        const self = job.server;
        defer {
            self.turn_done.store(true, .release);
            if (job.prompt) |prompt| self.gpa.free(prompt);
            agent_mod.freeImages(self.gpa, job.images);
            self.gpa.destroy(job);
        }

        var writer: EventWriter = .{
            .gpa = self.gpa,
            .out = &self.out,
            .cancel = &self.cancel,
            .agent = self.agent(),
        };
        defer writer.deinit();
        const listener: agent_mod.Agent.Listener = .{ .ptr = &writer, .on_event = EventWriter.onEvent };

        writer.emitSimple("agent_start") catch {};

        if (job.drain_queue) {
            _ = self.agent().drainAllQueuedToHistory() catch {};
        }
        if (job.prompt) |prompt| {
            self.agent().addUserPrompt(prompt, job.images) catch |err| {
                self.emitTurnError(&writer, err);
                writer.agentEnd() catch {};
                writer.emitSimple("agent_settled") catch {};
                return;
            };
        }

        self.agent().run(listener) catch |err| {
            if (err != error.TurnCancelled) self.emitTurnError(&writer, err);
        };
        writer.closeBlock() catch {};
        writer.agentEnd() catch {};
        writer.emitSimple("agent_settled") catch {};
        self.emitQueueUpdate();
    }

    fn emitTurnError(self: *Server, writer: *EventWriter, err: anyerror) void {
        _ = self;
        var buffer: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "agent turn failed: {s}", .{@errorName(err)}) catch "agent turn failed";
        writer.turnFailed(text) catch {};
    }

    fn respondOk(self: *Server, id: ?[]const u8, command: []const u8) void {
        self.respond(id, command, true, null, null);
    }

    fn respondData(self: *Server, id: ?[]const u8, command: []const u8, data_json: []const u8) void {
        self.respond(id, command, true, data_json, null);
    }

    fn respondError(self: *Server, id: ?[]const u8, command: []const u8, message: []const u8) void {
        self.respond(id, command, false, null, message);
    }

    fn respond(
        self: *Server,
        id: ?[]const u8,
        command: []const u8,
        success: bool,
        data_json: ?[]const u8,
        error_message: ?[]const u8,
    ) void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        w.writeAll("{") catch return;
        if (id) |value| {
            w.writeAll("\"id\":") catch return;
            std.json.Stringify.value(value, .{}, w) catch return;
            w.writeAll(",") catch return;
        }
        w.writeAll("\"type\":\"response\",\"command\":") catch return;
        std.json.Stringify.value(command, .{}, w) catch return;
        w.writeAll(",\"success\":") catch return;
        w.writeAll(if (success) "true" else "false") catch return;
        if (data_json) |data| {
            w.writeAll(",\"data\":") catch return;
            w.writeAll(data) catch return;
        }
        if (error_message) |message| {
            w.writeAll(",\"error\":") catch return;
            std.json.Stringify.value(message, .{}, w) catch return;
        }
        w.writeAll("}") catch return;
        self.out.writeLine(line.written());
    }

    fn emitQueueUpdate(self: *Server) void {
        var line: std.Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        const w = &line.writer;
        w.print(
            "{{\"type\":\"queue_update\",\"pending\":{d}}}",
            .{self.agent().queuedCount()},
        ) catch return;
        self.out.writeLine(line.written());
    }
};

/// One history message in the wire shape.
fn writeMessage(w: *std.Io.Writer, message: ai.ChatMessage) !void {
    switch (message.role) {
        .user => {
            try w.writeAll("{\"role\":\"user\",\"content\":");
            try std.json.Stringify.value(message.text(), .{}, w);
            try w.writeAll("}");
        },
        .assistant => {
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            var written: usize = 0;
            for (message.content) |block| {
                switch (block) {
                    .text => |text| {
                        if (text.text.len == 0) continue;
                        if (written > 0) try w.writeByte(',');
                        try w.writeAll("{\"type\":\"text\",\"text\":");
                        try std.json.Stringify.value(text.text, .{}, w);
                        try w.writeAll("}");
                        written += 1;
                    },
                    .tool_call => |call| {
                        if (written > 0) try w.writeByte(',');
                        try w.writeAll("{\"type\":\"toolCall\",\"id\":");
                        try std.json.Stringify.value(call.call_id, .{}, w);
                        try w.writeAll(",\"name\":");
                        try std.json.Stringify.value(call.name, .{}, w);
                        try w.writeAll(",\"arguments\":");
                        try writeRawJsonOrString(w, call.arguments);
                        try w.writeAll("}");
                        written += 1;
                    },
                    else => {},
                }
            }
            try w.writeAll("]}");
        },
        .tool => {
            try w.writeAll("{\"role\":\"toolResult\",\"toolCallId\":");
            try std.json.Stringify.value(message.call_id orelse "", .{}, w);
            try w.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(message.text(), .{}, w);
            try w.writeAll("}");
            // An image the tool attached is a second block, matching what
            // `tool_execution_end` reported for the same call.
            for (message.content) |block| {
                if (block != .image) continue;
                try w.writeAll(",{\"type\":\"image\",\"mimeType\":");
                try std.json.Stringify.value(block.image.mime_type, .{}, w);
                try w.writeAll(",\"data\":");
                try std.json.Stringify.value(block.image.data_base64, .{}, w);
                try w.writeAll("}");
            }
            try w.writeAll("],\"isError\":");
            try w.writeAll(if (message.tool_failed) "true" else "false");
            try w.writeAll("}");
        },
        .system => {},
    }
}

/// One model in the shape `set_model` and `get_available_models` both return.
fn writeModel(w: *std.Io.Writer, provider: config_mod.Provider, model_id: []const u8) !void {
    try w.writeAll("{\"provider\":");
    try std.json.Stringify.value(provider.label(), .{}, w);
    try w.writeAll(",\"id\":");
    try std.json.Stringify.value(model_id, .{}, w);
    try w.writeAll("}");
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// Largest single attachment, measured on the decoded bytes. We do not resize,
/// so an oversized image would sit in history and be re-sent on every later
/// request; refusing with a clear message beats silently inflating every
/// subsequent prompt.
const attachment_bytes_max: usize = 5 * 1024 * 1024;

/// Most attachments on one message. Bounds the work a single command can ask for.
const attachments_max: usize = 16;

/// Why an `images` array was rejected, as a message for the client. Null means
/// the array was absent or empty, which is the common case.
const ImageParse = union(enum) {
    images: []ai.ImageBlock,
    invalid: []const u8,
};

/// Parse Pi's `images` field: an array of `{type:"image", data, mimeType}`, where
/// `data` is base64. Returns owned blocks the caller must release with
/// `agent_mod.freeImages`.
///
/// Validation is strict at this boundary — base64 that does not decode, or a
/// mime type that is not an image, would otherwise travel all the way to the
/// provider and come back as an opaque HTTP error.
fn parseImages(gpa: std.mem.Allocator, object: std.json.ObjectMap) ImageParse {
    const value = object.get("images") orelse return .{ .images = &.{} };
    if (value == .null) return .{ .images = &.{} };
    if (value != .array) return .{ .invalid = "`images` must be an array" };
    const items = value.array.items;
    if (items.len == 0) return .{ .images = &.{} };
    if (items.len > attachments_max) return .{ .invalid = "too many images attached" };

    var list: std.ArrayList(ai.ImageBlock) = .empty;
    var ok = false;
    defer if (!ok) {
        for (list.items) |*image| image.deinit(gpa);
        list.deinit(gpa);
    };

    for (items) |item| {
        if (item != .object) return .{ .invalid = "each entry in `images` must be an object" };
        const entry = item.object;
        // `mime_type` is accepted alongside Pi's `mimeType` for the same reason
        // `edit` accepts `old_text` and `oldText`: models and clients spell it
        // both ways.
        const mime = stringField(entry, "mimeType") orelse stringField(entry, "mime_type") orelse {
            return .{ .invalid = "each image needs a `mimeType`" };
        };
        const data = stringField(entry, "data") orelse {
            return .{ .invalid = "each image needs base64 `data`" };
        };
        if (!std.mem.startsWith(u8, mime, "image/")) {
            return .{ .invalid = "`mimeType` must be an image/* type" };
        }
        if (data.len == 0) return .{ .invalid = "image `data` must not be empty" };
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data) catch {
            return .{ .invalid = "image `data` is not valid base64" };
        };
        if (decoded_len > attachment_bytes_max) {
            return .{ .invalid = "image is too large; downscale it before attaching" };
        }

        const mime_owned = gpa.dupe(u8, mime) catch return .{ .invalid = "out of memory" };
        const data_owned = gpa.dupe(u8, data) catch {
            gpa.free(mime_owned);
            return .{ .invalid = "out of memory" };
        };
        list.append(gpa, .{ .mime_type = mime_owned, .data_base64 = data_owned }) catch {
            gpa.free(mime_owned);
            gpa.free(data_owned);
            return .{ .invalid = "out of memory" };
        };
    }
    const owned = list.toOwnedSlice(gpa) catch return .{ .invalid = "out of memory" };
    ok = true;
    return .{ .images = owned };
}

test "line reader splits on LF only and strips a trailing CR" {
    const gpa = std.testing.allocator;
    var reader: LineReader = .{ .gpa = gpa };
    defer reader.deinit();

    try reader.push("{\"a\":1}\n{\"b\":2}\r\n");
    {
        const first = reader.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings("{\"a\":1}", first);
        reader.commit();
    }
    {
        const second = reader.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings("{\"b\":2}", second);
        reader.commit();
    }
    try std.testing.expect(reader.next() == null);
}

test "a Unicode line separator is not a record delimiter" {
    const gpa = std.testing.allocator;
    var reader: LineReader = .{ .gpa = gpa };
    defer reader.deinit();

    // U+2028 inside a JSON string must stay inside the record.
    try reader.push("{\"m\":\"a\u{2028}b\"}\n");
    const line = reader.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("{\"m\":\"a\u{2028}b\"}", line);
    reader.commit();
    try std.testing.expect(reader.next() == null);
}

test "partial input yields no record until its newline arrives" {
    const gpa = std.testing.allocator;
    var reader: LineReader = .{ .gpa = gpa };
    defer reader.deinit();

    try reader.push("{\"partial\":");
    try std.testing.expect(reader.next() == null);
    try reader.push("1}\n");
    const line = reader.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("{\"partial\":1}", line);
}

test "an oversized record is discarded and the next one still parses" {
    const gpa = std.testing.allocator;
    var reader: LineReader = .{ .gpa = gpa, .limit = 16 };
    defer reader.deinit();

    try reader.push("{\"huge\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"}\n{\"ok\":1}\n");
    try std.testing.expect(reader.takeOverflow());
    // Reported once, not once per query.
    try std.testing.expect(!reader.takeOverflow());

    const line = reader.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("{\"ok\":1}", line);
    reader.commit();
    try std.testing.expect(reader.next() == null);
}

test "an oversized record spanning several chunks is reported once" {
    const gpa = std.testing.allocator;
    var reader: LineReader = .{ .gpa = gpa, .limit = 8 };
    defer reader.deinit();

    try reader.push("aaaaaaaaaa");
    try std.testing.expect(reader.takeOverflow());
    // Still inside the doomed record: more of it is not a second failure.
    try reader.push("bbbbbbbbbb");
    try std.testing.expect(!reader.takeOverflow());
    try reader.push("cccc\n{\"ok\":1}\n");
    try std.testing.expect(!reader.takeOverflow());

    const line = reader.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("{\"ok\":1}", line);
}

test "the size cap applies per record, not to a backlog of small ones" {
    const gpa = std.testing.allocator;
    var reader: LineReader = .{ .gpa = gpa, .limit = 8 };
    defer reader.deinit();

    // Well past the cap in total, but no single record is.
    try reader.push("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n{\"d\":4}\n");
    try std.testing.expect(!reader.takeOverflow());
    for ([_][]const u8{ "{\"a\":1}", "{\"b\":2}", "{\"c\":3}", "{\"d\":4}" }) |expected| {
        const line = reader.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings(expected, line);
        reader.commit();
    }
    try std.testing.expect(reader.next() == null);
}
test "tool arguments pass through as JSON when valid and as a string when not" {
    const gpa = std.testing.allocator;
    {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try writeRawJsonOrString(&out.writer, "{\"command\":\"ls\"}");
        try std.testing.expectEqualStrings("{\"command\":\"ls\"}", out.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        // A truncated fragment must not be emitted raw.
        try writeRawJsonOrString(&out.writer, "{\"command\":");
        try std.testing.expectEqualStrings("\"{\\\"command\\\":\"", out.written());
    }
}

/// Drive an `EventWriter` over a buffer sink and hand back the emitted JSONL, so
/// a test asserts on the exact bytes a client would receive.
const Harness = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList(u8) = .empty,
    out: Output = undefined,
    cancel: std.atomic.Value(bool) = .init(false),
    /// A disconnected agent: never prompted, only used as the history the
    /// `turn_end` and `agent_end` payloads are read from.
    agent: agent_mod.Agent = undefined,
    writer: EventWriter = undefined,

    fn init(gpa: std.mem.Allocator) *Harness {
        const self = gpa.create(Harness) catch unreachable;
        self.* = .{ .gpa = gpa };
        self.out = Output.toBuffer(gpa, &self.lines);
        self.agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
        self.writer = .{ .gpa = gpa, .out = &self.out, .cancel = &self.cancel, .agent = &self.agent };
        return self;
    }

    fn deinit(self: *Harness) void {
        self.writer.deinit();
        self.agent.deinit();
        self.lines.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Feed one event, taking ownership the way the real listener does.
    fn send(self: *Harness, event: agent_mod.Agent.Event) !void {
        try EventWriter.onEvent(&self.writer, event);
    }

    /// Append a message to the agent's history, so a `turn_end` payload has
    /// something to report.
    fn record(self: *Harness, message: ai.ChatMessage) !void {
        try self.agent.takeMessage(message);
    }

    fn text(self: *Harness) []const u8 {
        return self.lines.items;
    }

    /// The `type` of every emitted record, in order — the shape assertions care
    /// about far more than the exact payloads.
    fn kinds(self: *Harness, buffer: [][]const u8) ![][]const u8 {
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, self.lines.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, line, .{});
            defer parsed.deinit();
            // Assistant deltas carry their real kind one level down.
            const outer = parsed.value.object.get("type").?.string;
            const inner = if (std.mem.eql(u8, outer, "message_update"))
                parsed.value.object.get("assistantMessageEvent").?.object.get("type").?.string
            else
                outer;
            buffer[count] = try self.gpa.dupe(u8, inner);
            count += 1;
        }
        return buffer[0..count];
    }

    fn freeKinds(self: *Harness, list: [][]const u8) void {
        for (list) |item| self.gpa.free(item);
    }
};

fn dup(gpa: std.mem.Allocator, text: []const u8) []const u8 {
    return gpa.dupe(u8, text) catch unreachable;
}

test "text deltas open a block, stream, and close with the assembled content" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .response_delta = dup(gpa, "Hello") });
    try h.send(.{ .response_delta = dup(gpa, " world") });
    try h.send(.delta_end);

    var buffer: [8][]const u8 = undefined;
    const kinds = try h.kinds(&buffer);
    defer h.freeKinds(kinds);
    try std.testing.expectEqual(@as(usize, 4), kinds.len);
    try std.testing.expectEqualStrings("text_start", kinds[0]);
    try std.testing.expectEqualStrings("text_delta", kinds[1]);
    try std.testing.expectEqualStrings("text_delta", kinds[2]);
    try std.testing.expectEqualStrings("text_end", kinds[3]);
    // The end event carries the whole block, so a client need not accumulate.
    try std.testing.expect(std.mem.indexOf(u8, h.text(), "\"content\":\"Hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.text(), "\"contentIndex\":0") != null);
}

test "switching from thinking to text closes the first block and advances the index" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .thinking_delta = dup(gpa, "pondering") });
    // No delta_end: the transition itself must close the thinking block, which is
    // what keeps a client's assembled message well-formed.
    try h.send(.{ .response_delta = dup(gpa, "answer") });
    try h.send(.delta_end);

    var buffer: [8][]const u8 = undefined;
    const kinds = try h.kinds(&buffer);
    defer h.freeKinds(kinds);
    try std.testing.expectEqualStrings("thinking_start", kinds[0]);
    try std.testing.expectEqualStrings("thinking_delta", kinds[1]);
    try std.testing.expectEqualStrings("thinking_end", kinds[2]);
    try std.testing.expectEqualStrings("text_start", kinds[3]);
    try std.testing.expectEqualStrings("text_delta", kinds[4]);
    try std.testing.expectEqualStrings("text_end", kinds[5]);
    try std.testing.expect(std.mem.indexOf(u8, h.text(), "\"contentIndex\":1") != null);
}

test "tool call deltas assemble into a toolcall_end carrying the whole call" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .tool_delta = .{
        .index = 0,
        .name = gpa.dupe(u8, "bash") catch unreachable,
        .arguments = gpa.dupe(u8, "{\"command\":") catch unreachable,
    } });
    try h.send(.{ .tool_delta = .{
        .index = 0,
        .name = gpa.dupe(u8, "bash") catch unreachable,
        .arguments = gpa.dupe(u8, "\"ls\"}") catch unreachable,
    } });
    try h.send(.delta_end);

    var buffer: [8][]const u8 = undefined;
    const kinds = try h.kinds(&buffer);
    defer h.freeKinds(kinds);
    try std.testing.expectEqualStrings("toolcall_start", kinds[0]);
    try std.testing.expectEqualStrings("toolcall_delta", kinds[1]);
    try std.testing.expectEqualStrings("toolcall_delta", kinds[2]);
    try std.testing.expectEqualStrings("toolcall_end", kinds[3]);
    try std.testing.expect(std.mem.indexOf(u8, h.text(), "\"toolName\":\"bash\"") != null);
    // The assembled arguments, not just the last fragment.
    try std.testing.expect(std.mem.indexOf(u8, h.text(), "{\\\"command\\\":\\\"ls\\\"}") != null);
}

test "tool execution events carry args as JSON and report isError" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .tool_call_started = .{
        .index = 0,
        .call_id = dup(gpa, "call_1"),
        .name = dup(gpa, "bash"),
        .arguments = dup(gpa, "{\"command\":\"ls\"}"),
    } });
    try h.send(.{ .tool_call_finished = .{
        .index = 0,
        .call_id = dup(gpa, "call_1"),
        .name = dup(gpa, "bash"),
        .content = dup(gpa, "a.txt\n"),
        .details_json = dup(gpa, "{\"truncated\":false}"),
        .failed = true,
    } });

    var buffer: [8][]const u8 = undefined;
    const kinds = try h.kinds(&buffer);
    defer h.freeKinds(kinds);
    try std.testing.expectEqualStrings("tool_execution_start", kinds[0]);
    try std.testing.expectEqualStrings("tool_execution_end", kinds[1]);

    const emitted = h.text();
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"toolCallId\":\"call_1\"") != null);
    // args pass through as an object, not a quoted string.
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"args\":{\"command\":\"ls\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"details\":{\"truncated\":false}") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"text\":\"a.txt\\n\"") != null);
}

test "an aborted turn stops the event stream at the next event" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .response_delta = dup(gpa, "before") });
    h.cancel.store(true, .release);
    // The listener signalling an error is how `Agent.run` unwinds a turn.
    try std.testing.expectError(error.TurnCancelled, h.send(.{ .response_delta = dup(gpa, "after") }));
    try std.testing.expect(std.mem.indexOf(u8, h.text(), "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.text(), "after") == null);
}

test "a failed turn is reported as an assistant message with an error stop reason" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .turn_failed = dup(gpa, "provider unreachable") });
    const emitted = h.text();
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"type\":\"message_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"stopReason\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "provider unreachable") != null);
}

test "every emitted record is one line of valid JSON" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    // A message containing the characters that break naive framing: a newline, a
    // quote, and the Unicode line separator that is legal inside a JSON string.
    try h.send(.{ .response_delta = dup(gpa, "line1\nline2 \"quoted\" \u{2028}sep") });
    try h.send(.delta_end);
    try h.send(.turn_finished);

    var records: usize = 0;
    var it = std.mem.splitScalar(u8, h.text(), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        records += 1;
    }
    // start + delta + end + turn_end, and the embedded newline did not split one.
    try std.testing.expectEqual(@as(usize, 4), records);
}

test "images parses Pi's attachment shape and rejects bad entries" {
    const gpa = std.testing.allocator;

    // A one-pixel payload; only the base64 has to be well formed here.
    const good =
        "{\"images\":[{\"type\":\"image\",\"data\":\"aGVsbG8=\",\"mimeType\":\"image/png\"}]}";
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, good, .{});
        defer parsed.deinit();
        switch (parseImages(gpa, parsed.value.object)) {
            .invalid => |reason| {
                std.debug.print("unexpected rejection: {s}\n", .{reason});
                return error.TestFailed;
            },
            .images => |images| {
                defer agent_mod.freeImages(gpa, images);
                try std.testing.expectEqual(@as(usize, 1), images.len);
                try std.testing.expectEqualStrings("image/png", images[0].mime_type);
                try std.testing.expectEqualStrings("aGVsbG8=", images[0].data_base64);
            },
        }
    }

    {
        const aliased = "{\"images\":[{\"data\":\"aGVsbG8=\",\"mime_type\":\"image/jpeg\"}]}";
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aliased, .{});
        defer parsed.deinit();
        const result = parseImages(gpa, parsed.value.object);
        try std.testing.expect(result == .images);
        defer agent_mod.freeImages(gpa, result.images);
        try std.testing.expectEqualStrings("image/jpeg", result.images[0].mime_type);
    }

    // Absent and empty both mean "no attachments", not an error.
    for ([_][]const u8{ "{}", "{\"images\":[]}", "{\"images\":null}" }) |source| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, source, .{});
        defer parsed.deinit();
        const result = parseImages(gpa, parsed.value.object);
        try std.testing.expect(result == .images);
        try std.testing.expectEqual(@as(usize, 0), result.images.len);
    }

    // Every rejection names what is wrong, since a client has to act on it.
    for ([_][]const u8{
        "{\"images\":\"nope\"}",
        "{\"images\":[\"nope\"]}",
        "{\"images\":[{\"data\":\"aGVsbG8=\"}]}",
        "{\"images\":[{\"mimeType\":\"image/png\"}]}",
        "{\"images\":[{\"data\":\"aGVsbG8=\",\"mimeType\":\"text/plain\"}]}",
        "{\"images\":[{\"data\":\"\",\"mimeType\":\"image/png\"}]}",
        "{\"images\":[{\"data\":\"not base64 !!\",\"mimeType\":\"image/png\"}]}",
    }) |source| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, source, .{});
        defer parsed.deinit();
        const result = parseImages(gpa, parsed.value.object);
        if (result == .images) {
            agent_mod.freeImages(gpa, result.images);
            std.debug.print("expected rejection for: {s}\n", .{source});
            return error.TestFailed;
        }
        try std.testing.expect(result.invalid.len > 0);
    }
}

test "an attached image becomes a second content block on the tool result" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .tool_call_finished = .{
        .index = 0,
        .call_id = dup(gpa, "call_1"),
        .name = dup(gpa, "view_image"),
        .content = dup(gpa, "Attached image/png for viewing: shot.png (32 bytes)."),
        .image = .{
            .mime_type = dupMut(gpa, "image/png"),
            .data_base64 = dupMut(gpa, "aGVsbG8="),
        },
    } });

    const emitted = h.text();
    // Text first, then the image — in the same shape `prompt` accepts, so a
    // client can hand it straight back.
    const text_at = std.mem.indexOf(u8, emitted, "\"type\":\"text\"") orelse return error.TestFailed;
    const image_at = std.mem.indexOf(u8, emitted, "\"type\":\"image\"") orelse return error.TestFailed;
    try std.testing.expect(text_at < image_at);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"mimeType\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"data\":\"aGVsbG8=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"isError\":false") != null);

    // Still one line of valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trimEnd(u8, emitted, "\n"), .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("result").?.object.get("content").?;
    try std.testing.expectEqual(@as(usize, 2), content.array.items.len);
}

test "a tool result with no image emits a single content block" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.{ .tool_call_finished = .{
        .index = 0,
        .call_id = dup(gpa, "call_1"),
        .name = dup(gpa, "bash"),
        .content = dup(gpa, "ok\n"),
    } });
    const emitted = h.text();
    try std.testing.expect(std.mem.indexOf(u8, emitted, "\"type\":\"image\"") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trimEnd(u8, emitted, "\n"), .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("result").?.object.get("content").?;
    try std.testing.expectEqual(@as(usize, 1), content.array.items.len);
}

/// Owned copy typed as mutable, for the `ai.ImageBlock` fields.
fn dupMut(gpa: std.mem.Allocator, text: []const u8) []u8 {
    return gpa.dupe(u8, text) catch unreachable;
}

test "turn_end carries the turn's assistant message and its tool results" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    // A message from before the turn must not be reported as part of it.
    try h.record(.{ .role = .user, .content = try textBlocks(gpa, "earlier") });
    try h.send(.turn_started);

    var assistant_blocks = try gpa.alloc(ai.ContentBlock, 2);
    assistant_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "Looking.") } };
    assistant_blocks[1] = .{ .tool_call = .{
        .call_id = try gpa.dupe(u8, "call_1"),
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"ls\"}"),
    } };
    try h.record(.{ .role = .assistant, .content = assistant_blocks });
    try h.record(.{
        .role = .tool,
        .content = try textBlocks(gpa, "a.txt\n"),
        .call_id = try gpa.dupe(u8, "call_1"),
    });
    try h.send(.turn_finished);

    const emitted = h.text();
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, lastLine(emitted), .{});
    defer parsed.deinit();
    const record = parsed.value.object;
    try std.testing.expectEqualStrings("turn_end", record.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 0), record.get("turnIndex").?.integer);

    const message = record.get("message").?.object;
    try std.testing.expectEqualStrings("assistant", message.get("role").?.string);
    const content = message.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("Looking.", content[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("toolCall", content[1].object.get("type").?.string);

    const results = record.get("toolResults").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("call_1", results[0].object.get("toolCallId").?.string);
    try std.testing.expect(!results[0].object.get("isError").?.bool);
}

test "a second turn reports only its own messages and a fresh index" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.send(.turn_started);
    try h.record(.{ .role = .assistant, .content = try textBlocks(gpa, "first") });
    try h.send(.turn_finished);

    try h.send(.turn_started);
    try h.record(.{ .role = .assistant, .content = try textBlocks(gpa, "second") });
    try h.send(.turn_finished);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, lastLine(h.text()), .{});
    defer parsed.deinit();
    const record = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), record.get("turnIndex").?.integer);
    const content = record.get("message").?.object.get("content").?.array.items;
    // Only the second turn's text, not the first's.
    try std.testing.expectEqual(@as(usize, 1), content.len);
    try std.testing.expectEqualStrings("second", content[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(usize, 0), record.get("toolResults").?.array.items.len);
}

test "agent_end carries the conversation without the system prompt" {
    const gpa = std.testing.allocator;
    const h = Harness.init(gpa);
    defer h.deinit();

    try h.record(.{ .role = .system, .content = try textBlocks(gpa, "You are Nova.") });
    try h.record(.{ .role = .user, .content = try textBlocks(gpa, "hi") });
    try h.record(.{ .role = .assistant, .content = try textBlocks(gpa, "hello") });
    try h.writer.agentEnd();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, lastLine(h.text()), .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("assistant", messages[1].object.get("role").?.string);
}

/// One text block, owned, as `ai.ChatMessage.content` expects.
fn textBlocks(gpa: std.mem.Allocator, text: []const u8) ![]ai.ContentBlock {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return blocks;
}

/// The last complete record in a JSONL buffer.
fn lastLine(emitted: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, emitted, "\n");
    const start = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return trimmed[start + 1 ..];
}
