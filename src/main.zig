const std = @import("std");
const nova = @import("nova");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const base_url = init.environ_map.get("OPENAI_BASE_URL") orelse "https://api.openai.com";
    const api_key = init.environ_map.get("OPENAI_API_KEY") orelse "";
    const model = init.environ_map.get("OPENAI_MODEL") orelse "gpt-5.5";
    const system_prompt =
        \\You are a helpful coding agent. Use read to inspect files and directories, edit_file for targeted hashline edits, write_file for whole-file writes, search_codebase when available, and bash for ordinary shell commands.
        \\Always make sure the user is not delegating their thinking to you, or getting you to design the entire solution for them. Always ensure
        \\the user understands what you're doing. If the user is delegating their thinking to you, push back and ask them insightful questions that probe their understanding further.
    ;

    const cwd = try std.process.currentPathAlloc(init.io, gpa);
    defer gpa.free(cwd);

    const tools_json = try nova.tools.buildToolsJson(gpa);
    defer gpa.free(tools_json);

    var openai_client: nova.ai.openai.Client = undefined;
    try openai_client.init(gpa, init.io, .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .tools_json = tools_json,
    });
    defer openai_client.deinit();

    var agent = nova.agent.Agent.init(gpa, init.io, cwd, .{ .openai = &openai_client });
    defer agent.deinit();
    // TODO: Add more things to the system prompt
    try agent.addSystem(system_prompt);

    try nova.tui.run(init, &agent);
}
