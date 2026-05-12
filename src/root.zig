pub const agent = @import("agent.zig");
pub const ai = @import("ai.zig");
pub const bash = @import("bash.zig");
pub const thread = @import("thread.zig");
pub const tui = @import("tui.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("bash/commands.zig");
    _ = @import("bash/handlers.zig");
    _ = @import("bash/parse.zig");
}
