const std = @import("std");

const assert = std.debug.assert;

pub const DisplayKind = enum(u8) { text, diff };

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    display: ?[]u8 = null,
    display_kind: DisplayKind = .text,
    observation: ?Observation = null,

    pub fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        if (self.display) |display| gpa.free(display);
        if (self.observation) |*observation| observation.deinit(gpa);
        self.* = undefined;
    }
};

pub const Observation = union(enum) {
    complete: []u8,
    truncated_tail: TruncatedTail,

    pub const TruncatedTail = struct {
        text: []u8,
        total_lines: u32,
        shown_lines: u32,
        total_bytes: u64,
        shown_bytes: u32,
        full_output_path: []u8,
    };

    pub fn deinit(self: *Observation, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .complete => |text| gpa.free(text),
            .truncated_tail => |tail| {
                gpa.free(tail.text);
                gpa.free(tail.full_output_path);
            },
        }
        self.* = undefined;
    }

    pub fn render(self: Observation, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return switch (self) {
            .complete => |text| gpa.dupe(u8, text),
            .truncated_tail => |tail| std.fmt.allocPrint(
                gpa,
                "{s}\n\n[Showing last {d} of {d} lines ({d} of {d} bytes). Full output: {s}]",
                .{ tail.text, tail.shown_lines, tail.total_lines, tail.shown_bytes, tail.total_bytes, tail.full_output_path },
            ),
        };
    }
};

pub const Error = error{
    OutOfMemory,
} || std.Io.Cancelable || std.Io.UnexpectedError;

pub const ToolDisplay = struct {
    /// Human-facing summary shown while the tool is collapsed.
    label: []u8,
    /// Machine-facing detail shown in place of `label` when expanded.
    expanded_label: ?[]u8 = null,

    pub fn deinit(self: *ToolDisplay, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
        if (self.expanded_label) |label| gpa.free(label);
        self.* = undefined;
    }
};

/// A typed record describing one tool. The Tool registry in `tools.zig`
/// is a slice of these; it is the single source of truth for what tools
/// exist. Display policy (Expand-by-default, render mode) is NOT carried
/// here — that lives TUI-side.
pub const Tool = struct {
    name: []const u8,
    /// Raw description template. May contain `{{hsep}}` placeholders that
    /// each LanguageModel adapter substitutes with `~` before sending.
    description: []const u8,
    schema: Schema,
    run: *const fn (
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const u8,
    ) Error!Output,
    /// Produce the human display metadata shown in the TUI's tool row.
    /// `label` is the collapsed summary; `expanded_label`, when present,
    /// replaces it while the row is expanded.
    display: *const fn (
        gpa: std.mem.Allocator,
        args: []const u8,
    ) std.mem.Allocator.Error!ToolDisplay,
};

pub const Schema = struct {
    properties: []const Property,

    pub const Property = struct {
        name: []const u8,
        kind: Kind,
        description: []const u8,
        required: bool,
    };

    /// A parameter's JSON type. Arrays carry their element shape so a tool can
    /// declare a list of strings (`grep`'s patterns) or a list of records
    /// (`edit`'s replacements) without hand-writing JSON Schema.
    pub const Kind = union(enum) {
        string,
        integer,
        object,
        boolean,
        string_array,
        /// Array of objects with these fields. Nested fields may not themselves
        /// be arrays — one level is all any tool needs, and the writer below
        /// asserts it rather than silently emitting a wrong schema.
        object_array: []const Property,
    };

    /// Write this schema as a JSON Schema `object` — the `parameters` value every
    /// provider expects. Shared by the adapters so the wire format can't drift
    /// between them, and so array support only had to be written once.
    pub fn writeJson(self: Schema, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"type\":\"object\",\"properties\":{");
        for (self.properties, 0..) |property, index| {
            if (index > 0) try writer.writeByte(',');
            try writeProperty(writer, property, true);
        }
        try writer.writeAll("},\"required\":[");
        var required: u32 = 0;
        for (self.properties) |property| {
            if (!property.required) continue;
            if (required > 0) try writer.writeByte(',');
            try std.json.Stringify.value(property.name, .{}, writer);
            required += 1;
        }
        try writer.writeAll("]}");
    }

    fn writeProperty(writer: *std.Io.Writer, property: Property, comptime nestable: bool) !void {
        try std.json.Stringify.value(property.name, .{}, writer);
        try writer.writeAll(":");
        switch (property.kind) {
            .string, .integer, .object, .boolean => {
                try writer.writeAll("{\"type\":");
                try std.json.Stringify.value(scalarTypeName(property.kind), .{}, writer);
            },
            .string_array => {
                try writer.writeAll("{\"type\":\"array\",\"items\":{\"type\":\"string\"}");
            },
            .object_array => |fields| {
                if (!nestable) unreachable; // one level of nesting only
                try writer.writeAll("{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{");
                for (fields, 0..) |field, index| {
                    if (index > 0) try writer.writeByte(',');
                    try writeProperty(writer, field, false);
                }
                try writer.writeAll("},\"required\":[");
                var required: u32 = 0;
                for (fields) |field| {
                    if (!field.required) continue;
                    if (required > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(field.name, .{}, writer);
                    required += 1;
                }
                try writer.writeAll("]}");
            },
        }
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(property.description, .{}, writer);
        try writer.writeByte('}');
    }

    fn scalarTypeName(kind: Kind) []const u8 {
        return switch (kind) {
            .string => "string",
            .integer => "integer",
            .object => "object",
            .boolean => "boolean",
            .string_array, .object_array => unreachable,
        };
    }
};

pub fn ok(gpa: std.mem.Allocator, stdout: []u8) Error!Output {
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0, .display = null };
}

pub fn okWithDisplay(gpa: std.mem.Allocator, stdout: []u8, display: []u8) Error!Output {
    assert(stdout.len > 0);
    assert(display.len > 0);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = 0, .display = display };
}

pub fn fail(gpa: std.mem.Allocator, message: []const u8, code: u8) Error!Output {
    assert(code != 0);
    assert(message.len > 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try gpa.dupe(u8, message);
    return .{ .stdout = stdout, .stderr = stderr, .code = code, .display = null };
}

pub fn failFmt(
    gpa: std.mem.Allocator,
    code: u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!Output {
    assert(code != 0);
    const stdout = try gpa.alloc(u8, 0);
    errdefer gpa.free(stdout);
    const stderr = try std.fmt.allocPrint(gpa, fmt, args);
    return .{ .stdout = stdout, .stderr = stderr, .code = code, .display = null };
}

/// Helper for display implementations. Parses the argument JSON and extracts
/// a single string field; returns the bare `fallback` (owned) when the JSON is
/// partial / invalid / missing the field.
pub fn readFileBytes(gpa: std.mem.Allocator, io: std.Io, absolute: []const u8, bytes_max: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, absolute, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(bytes_max)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

pub fn joinPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ cwd, path });
}

pub fn mapAllocError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.Unexpected,
    };
}

pub fn extractStringField(
    gpa: std.mem.Allocator,
    args: []const u8,
    field: []const u8,
    fallback: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (args.len == 0) return gpa.dupe(u8, fallback);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, args, .{}) catch {
        return gpa.dupe(u8, fallback);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return gpa.dupe(u8, fallback);
    const value = parsed.value.object.get(field) orelse return gpa.dupe(u8, fallback);
    if (value != .string) return gpa.dupe(u8, fallback);
    return gpa.dupe(u8, value.string);
}
