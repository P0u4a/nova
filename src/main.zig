const std = @import("std");
const nova = @import("nova");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const base_url = init.environ_map.get("OPENAI_BASE_URL") orelse "https://api.openai.com";
    const api_key = init.environ_map.get("OPENAI_API_KEY") orelse "";
    const model = init.environ_map.get("OPENAI_MODEL") orelse "gpt-5.5";

    var agent = nova.agent.Agent.init(gpa, init.io, .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
    });
    defer agent.deinit();

    try nova.tui.run(init, &agent);
}
