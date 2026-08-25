const std = @import("std");

pub const agent = @import("agent.zig");
pub const ai = @import("ai.zig");
pub const at_mention = @import("at_mention.zig");
pub const background = @import("background.zig");
pub const bash = @import("bash.zig");
pub const local_models = @import("local_models.zig");
pub const bash_safety = @import("bash_safety.zig");
pub const codex = @import("codex.zig");
pub const compaction = @import("compaction.zig");
pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const db = @import("db.zig");
pub const executor = @import("executor.zig");
pub const image = @import("image.zig");
pub const image_png = @import("image/png.zig");
pub const image_raster = @import("image/raster.zig");
pub const os = @import("os.zig");
pub const search = @import("search.zig");
pub const session = @import("session.zig");
pub const skill = @import("skill.zig");
pub const symbols = @import("symbols.zig");
pub const logger = @import("logger");
pub const runtime = @import("runtime.zig");
pub const rpc = @import("rpc.zig");
pub const vcs = @import("vcs.zig");
pub const tools = @import("tools.zig");

pub fn run(init: std.process.Init, gpa: std.mem.Allocator) !void {
    @import("bash.zig").disablePseudoConsole();

    if (logger.enabled) {
        if (resolveLogPath(gpa, init.environ_map)) |log_path| {
            defer gpa.free(log_path);
            try logger.init(.{ .io = init.io, .log_path = log_path });
        } else |_| {}
    }
    defer logger.deinit();

    const cwd = try std.process.currentPathAlloc(init.io, gpa);
    defer gpa.free(cwd);

    const home_dir = try resolveHomeDir(gpa, init.environ_map);
    defer gpa.free(home_dir);

    var load_result = try config.load(gpa, init.io, cwd, home_dir, init.environ_map);
    var local_models_handle: ?local_models.Server = null;
    if (load_result.config.bash_classifier_url == null) {
        local_models_handle = try local_models.ensure(gpa, init.io, cwd);
        errdefer if (local_models_handle) |*server| server.deinit(gpa, init.io);
        if (local_models_handle) |server| {
            load_result.config.bash_classifier_url = try gpa.dupe(u8, server.url);
        }
    }
    defer if (local_models_handle) |*server| server.deinit(gpa, init.io);

    // Long-running and streaming unbounded content, so a real freeing allocator
    // is required — an arena would never reclaim. `smp_allocator` is a
    // thread-safe global singleton, which the turn thread also needs.
    const runtime_gpa = std.heap.smp_allocator;
    defer search.deinit(runtime_gpa, init.io);

    // Warm the file index in the background so the first `find`/`grep` does not
    // fall back to the shell.
    search.start(runtime_gpa, init.io, cwd);

    const system_prompt = if (load_result.config.system_prompt) |s| s else @embedFile("prompts/system.md");
    const agent_runtime = try runtime_gpa.create(runtime.AgentRuntime);
    defer runtime_gpa.destroy(agent_runtime);
    try agent_runtime.initNew(
        runtime_gpa,
        init.io,
        cwd,
        cwd,
        home_dir,
        system_prompt,
        load_result.config,
        load_result.takeDiagnostics(),
        null,
    );
    defer agent_runtime.deinit();

    var server = rpc.Server.init(runtime_gpa, init.io, agent_runtime, cwd, load_result.config);
    defer server.deinit();
    try server.run();

    load_result.config.deinit(gpa);
}

fn resolveLogPath(gpa: std.mem.Allocator, env: anytype) ![]u8 {
    if (env.get("NOVA_LOG_FILE")) |path| return gpa.dupe(u8, path);
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".nova", "nova.log" });
}

fn resolveHomeDir(gpa: std.mem.Allocator, env: anytype) std.mem.Allocator.Error![]u8 {
    if (env.get("HOME")) |home| return gpa.dupe(u8, home);
    if (env.get("USERPROFILE")) |home| return gpa.dupe(u8, home);
    return gpa.dupe(u8, "");
}

test {
    std.testing.refAllDecls(@This());
}
