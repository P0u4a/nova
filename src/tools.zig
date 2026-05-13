/// Public surface for nova's custom in-process tools. The agent calls
/// bash and the dispatcher intercepts segments whose
/// argv[0] names one of our tools and runs them in-process.
const std = @import("std");

const common = @import("tools/common.zig");
const dispatch = @import("tools/dispatch.zig");
const edit_file = @import("tools/edit_file.zig");
const fast_search = @import("tools/fast_search.zig");
const read_file = @import("tools/read_file.zig");
const write_file = @import("tools/write_file.zig");

pub const Output = common.Output;
pub const Error = common.Error;
pub const tryHandle = dispatch.tryHandle;

/// Description sent to the model as the `bash` tool's `description` field.
/// This is where the custom-utility roster lives, because most models read
/// the tool description more carefully than the system prompt.
pub const bash_tool_description =
    \\Execute shell commands. This is the only way to navigate the project, read files, run programs, or make edits. 
    \\Call this tool everytime you need to touch project. There are
    \\a few important commands you should prefer over POSIX equivalents:
    \\
    \\  read-file   instead of cat, head, tail, sed -n 'A,Bp'
    \\  write-file  instead of `> file` redirects for whole-file writes
    \\  edit-file   instead of sed -i for in-place edits
    \\  fast-search instead of grep or rg
    \\How to use these specific commands:
++ read_file.help_text ++ "\n\n" ++
    write_file.help_text ++ "\n\n" ++
    edit_file.help_text ++ "\n\n" ++
    fast_search.help_text ++ "\n\n" ++
    \\When doing file edits, read once with read-file command to get hashline anchors, then issue
    \\targeted edits with edit-file command using those anchors. Each command
    \\supports `--help` for when you're stuck.
    \\You can still use all other bash commands like cd, ls, mkdir, mv.
;
/// Build the JSON value for the OpenAI request's `tools` field. Allocates
/// once at startup; the caller frees on shutdown.
pub fn buildToolsJson(gpa: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\[{"type":"function","function":{"name":"bash","description":
    );
    try std.json.Stringify.value(bash_tool_description, .{}, w);
    try w.writeAll(
        \\,"parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}]
    );
    return aw.toOwnedSlice();
}

test {
    _ = common;
    _ = dispatch;
    _ = @import("tools/handlers.zig");
    _ = @import("tools/parse.zig");
    _ = @import("tools/hashline/hash.zig");
    _ = @import("tools/hashline/parse.zig");
    _ = @import("tools/hashline/apply.zig");
    _ = read_file;
    _ = write_file;
    _ = edit_file;
    _ = fast_search;
}
