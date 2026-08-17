//! Workspace — the lanes a developer has open and every operation that acts on
//! them: forking a lane into its own git worktree, parking/abandoning/merging
//! one, switching sessions, moving along the timeline, taking checkpoints, and
//! routing finished background jobs back to the lane that started them.

const std = @import("std");

const agent_mod = @import("agent.zig");
const background_mod = @import("background.zig");
const config_mod = @import("config.zig");
const naming_mod = @import("tui/naming.zig");
const runtime_mod = @import("runtime.zig");
const vcs = @import("vcs.zig");
const Thread = @import("tui/thread.zig");

const assert = std.debug.assert;

pub const lanes_max: usize = 4;

pub const Error = error{
    InFlightTurn,
    NoActiveRuntime,
    TooManyLanes,
    NotAGitRepo,
    CannotClosePrimaryLane,
    CannotMergePrimaryLane,
    NoMergeDestination,
    MergeConflict,
};

pub const Delivery = struct {
    owner: *anyopaque,
    label: []u8,
    command: []u8,
    exit_code: u8,
    killed: bool,
    message: ?[]u8,
};

/// The lane a merge is folding in. `active_index` is set when the source is an
/// open lane (so it can be torn down afterwards) and null when it is a parked
/// worktree that was never opened.
pub const MergeSource = struct {
    branch: []const u8,
    path: []const u8,
    active_index: ?usize,
};

pub const Workspace = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    lanes: std.ArrayList(*Thread) = .empty,
    active: *Thread,
    background: ?*background_mod.BackgroundManager = null,
    background_pending: std.ArrayList(Delivery) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, primary: *Thread) !Workspace {
        var lanes: std.ArrayList(*Thread) = .empty;
        errdefer lanes.deinit(gpa);
        try lanes.append(gpa, primary);
        return .{
            .gpa = gpa,
            .io = io,
            .lanes = lanes,
            .active = primary,
        };
    }

    /// Tear down every lane, in the one order that is safe: cancel in-flight
    /// turns and naming jobs first (so no worker outlives the workspace), then
    /// the background manager (so no worker can still be inside `manager.start`),
    /// then the lanes themselves.
    pub fn deinit(self: *Workspace) void {
        for (self.lanes.items) |lane| {
            if (lane.turn_future) |*future| {
                if (lane.worker_context) |*worker| worker.requestCancel();
                _ = future.cancel(self.io);
                lane.turn_future = null;
            }
            self.cancelNaming(lane);
        }
        // Jobs hold an opaque owner token that is never dereferenced, so this is
        // independent of lane/agent teardown order. Terminates and joins every
        // job (killing the whole process tree on Windows via its Job Object).
        if (self.background) |manager| {
            manager.deinit();
            self.gpa.destroy(manager);
            self.background = null;
        }
        for (self.background_pending.items) |*delivery| self.freeDelivery(delivery);
        self.background_pending.deinit(self.gpa);
        for (self.lanes.items) |lane| {
            lane.deinit(self.gpa);
            self.gpa.destroy(lane);
        }
        self.lanes.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn liveRuntime(self: *const Workspace) ?*runtime_mod.AgentRuntime {
        return switch (self.active.engine) {
            .live => |live| live.runtime,
            .idle => null,
        };
    }

    pub fn templateRuntime(self: *const Workspace) ?*runtime_mod.AgentRuntime {
        for (self.lanes.items) |lane| {
            switch (lane.engine) {
                .live => |live| return live.runtime,
                .idle => {},
            }
        }
        return null;
    }

    pub fn repoRoot(self: *const Workspace) ?[]const u8 {
        return switch (self.lanes.items[0].engine) {
            .live => |live| live.runtime.cwd,
            .idle => null,
        };
    }

    pub fn activeIndex(self: *const Workspace) usize {
        for (self.lanes.items, 0..) |lane, index| {
            if (lane == self.active) return index;
        }
        return 0;
    }

    pub fn anyTurnActive(self: *const Workspace) bool {
        for (self.lanes.items) |lane| {
            if (lane.turn.state != .idle) return true;
        }
        return false;
    }

    pub fn laneForAgent(self: *Workspace, agent_ptr: *agent_mod.Agent) ?*Thread {
        for (self.lanes.items) |lane| {
            if (lane.agent) |a| {
                if (a == agent_ptr) return lane;
            }
        }
        return null;
    }

    pub fn workingLaneOf(lane: *Thread) ?vcs.Lane.Working {
        return switch (lane.engine) {
            .live => |live| switch (live.lane) {
                .working => |w| w,
                .primary => null,
            },
            .idle => |l| switch (l) {
                .working => |w| w,
                .primary => null,
            },
        };
    }

    pub fn checkpoint(self: *Workspace) agent_mod.Agent.SnapshotOutcome {
        const agent = self.active.agent orelse return .unavailable;
        return agent.snapshotNow();
    }

    fn restoreCheckpoint(self: *Workspace, rt: *runtime_mod.AgentRuntime) !void {
        const sha_raw = (try rt.session_writer.snapshotAt(self.gpa)) orelse return;
        defer self.gpa.free(sha_raw);
        const sha = vcs.ObjectId.parse(sha_raw) catch return;
        const index = vcs.indexPath(self.gpa, self.io, rt.cwd) catch return;
        defer self.gpa.free(index);
        vcs.restore(self.gpa, self.io, rt.cwd, index, sha) catch return;
    }

    pub fn navigateToEntry(self: *Workspace, entry_id: []const u8) !void {
        if (self.active.turn.isActive()) return Error.InFlightTurn;
        const rt = self.liveRuntime() orelse return Error.NoActiveRuntime;
        try rt.session_writer.navigate(entry_id);
        try rt.reloadMessages();
        if (self.active.agent) |agent| agent.last_snapshot_tree = null;
        try self.restoreCheckpoint(rt);
    }

    pub fn createRuntime(
        self: *Workspace,
        config: config_mod.Config,
        cwd: []const u8,
        session_dir: []const u8,
        session_id: ?[]const u8,
    ) !*runtime_mod.AgentRuntime {
        const current = self.templateRuntime() orelse return Error.NoActiveRuntime;
        const runtime = try self.gpa.create(runtime_mod.AgentRuntime);
        errdefer self.gpa.destroy(runtime);
        const diagnostics = try current.gpa.alloc(config_mod.Diagnostic, 0);
        errdefer current.gpa.free(diagnostics);
        if (session_id) |id| {
            try runtime.initResume(
                current.gpa,
                self.io,
                cwd,
                session_dir,
                current.home_dir,
                current.base_system_prompt,
                config,
                diagnostics,
                id,
                current, // template: reuse the live lane's project prompt + skills
            );
        } else {
            try runtime.initNew(
                current.gpa,
                self.io,
                cwd,
                session_dir,
                current.home_dir,
                current.base_system_prompt,
                config,
                diagnostics,
                current, // template: reuse the live lane's project prompt + skills
            );
        }
        // Every lane shares the one background manager so jobs survive lane
        // switches and are all torn down together at exit.
        runtime.agent.background_manager = self.background;
        return runtime;
    }

    pub fn installRuntime(self: *Workspace, runtime: *runtime_mod.AgentRuntime) !void {
        if (self.active.turn.isActive()) return Error.InFlightTurn;
        self.cancelNaming(self.active);
        if (self.liveRuntime()) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.active.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = true } };
        self.active.agent = &runtime.agent;
        self.active.id = runtime.session_writer.session.id;
        if (self.active.title) |title| self.gpa.free(title);
        self.active.title = null;
    }

    pub fn switchToSession(self: *Workspace, config: config_mod.Config, session_id: ?[]const u8) !void {
        if (self.active.turn.isActive()) return Error.InFlightTurn;
        const rt = self.liveRuntime() orelse return Error.NoActiveRuntime;
        const runtime = try self.createRuntime(config, rt.cwd, self.repoRoot() orelse rt.cwd, session_id);
        errdefer {
            runtime.deinit();
            self.gpa.destroy(runtime);
        }
        try self.installRuntime(runtime);
    }

    pub fn createLane(self: *Workspace, config: config_mod.Config, parent_context: [][]u8) !*Thread {
        if (self.lanes.items.len >= lanes_max) return Error.TooManyLanes;
        const repo = self.repoRoot() orelse return Error.NoActiveRuntime;
        const home = (self.liveRuntime() orelse return Error.NoActiveRuntime).home_dir;
        if (!vcs.isRepo(self.gpa, self.io, repo)) return Error.NotAGitRepo;

        var raw: [6]u8 = undefined;
        self.io.random(&raw);
        const id = std.fmt.bytesToHex(raw, .lower);

        const branch = try std.fmt.allocPrint(self.gpa, "nova/{s}", .{id[0..]});
        errdefer self.gpa.free(branch);

        // Worktrees live under the global `<home>/.nova/worktrees`, outside the
        // repo, so `git add -A`/snapshots/`/save` never see them.
        const parent = try std.fs.path.join(self.gpa, &.{ home, ".nova", "worktrees" });
        defer self.gpa.free(parent);
        std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
        const dest = try std.fs.path.join(self.gpa, &.{ parent, id[0..] });
        errdefer self.gpa.free(dest);

        try vcs.worktreeAdd(self.gpa, self.io, repo, dest, branch);
        errdefer vcs.worktreeRemove(self.gpa, self.io, repo, dest) catch {};

        const runtime = try self.createRuntime(config, dest, repo, null);
        errdefer {
            runtime.deinit();
            self.gpa.destroy(runtime);
        }

        const lane = try self.gpa.create(Thread);
        errdefer self.gpa.destroy(lane);
        lane.* = .{
            .id = runtime.session_writer.session.id,
            .agent = &runtime.agent,
            .worker_context = .{ .io = self.io, .gpa = runtime.gpa },
            .parent_context = parent_context,
            .engine = .{ .live = .{
                .lane = .{ .working = .{ .branch = branch, .path = dest } },
                .runtime = runtime,
                .owns = true,
            } },
        };
        try self.lanes.append(self.gpa, lane);

        self.active = lane;
        return lane;
    }

    pub fn closeActiveLane(self: *Workspace) !void {
        if (self.active.turn.isActive()) return Error.InFlightTurn;
        const index = self.activeIndex();
        if (index == 0) return Error.CannotClosePrimaryLane;

        const lane = self.lanes.items[index];
        self.cancelNaming(lane);
        self.active = self.lanes.items[index - 1];
        _ = self.lanes.orderedRemove(index);
        lane.deinit(self.gpa);
        self.gpa.destroy(lane);
    }

    pub fn abandonLane(self: *Workspace, index: usize) !void {
        assert(index != 0);
        const lane = self.lanes.items[index];
        assert(lane != self.active);
        var branch: ?[]u8 = null;
        var dir: ?[]u8 = null;
        if (workingLaneOf(lane)) |w| {
            branch = try self.gpa.dupe(u8, w.branch);
            dir = try self.gpa.dupe(u8, w.path);
        }
        defer if (branch) |b| self.gpa.free(b);
        defer if (dir) |d| self.gpa.free(d);

        self.cancelNaming(lane);
        _ = self.lanes.orderedRemove(index);
        lane.deinit(self.gpa);
        self.gpa.destroy(lane);

        if (self.repoRoot()) |repo| {
            if (dir) |d| vcs.worktreeRemove(self.gpa, self.io, repo, d) catch {};
            if (branch) |b| vcs.deleteBranch(self.gpa, self.io, repo, b) catch {};
        }
    }

    pub fn laneMergeDir(self: *Workspace, lane: *Thread) ?[]const u8 {
        if (workingLaneOf(lane)) |w| return w.path;
        return self.repoRoot();
    }

    pub fn mergeLane(self: *Workspace, source: MergeSource, dest: *Thread) !void {
        if (dest.turn.isActive()) return Error.InFlightTurn;
        if (source.active_index) |si| {
            if (self.lanes.items[si].turn.isActive()) return Error.InFlightTurn;
        }
        const dest_dir = self.laneMergeDir(dest) orelse return Error.NoActiveRuntime;

        if (try vcs.workingTreeDirty(self.gpa, self.io, source.path)) {
            try vcs.commitAll(self.gpa, self.io, source.path, "nova: merge lane");
        }

        switch (try vcs.merge(self.gpa, self.io, dest_dir, source.branch)) {
            .conflict => return Error.MergeConflict,
            .ok => {},
        }

        self.active = dest;
        if (source.active_index) |si| {
            try self.abandonLane(si);
        } else if (self.repoRoot()) |repo| {
            vcs.worktreeRemove(self.gpa, self.io, repo, source.path) catch {};
            vcs.deleteBranch(self.gpa, self.io, repo, source.branch) catch {};
        }
        // The destination's tree just changed underneath the agent; force the
        // next checkpoint to write a node rather than dedup against a stale tree.
        if (dest.agent) |agent| agent.last_snapshot_tree = null;
    }

    pub fn collectParkedLanes(self: *Workspace, repo: []const u8) ![]vcs.WorktreeEntry {
        const all = try vcs.worktreeList(self.gpa, self.io, repo);
        defer vcs.freeWorktreeList(self.gpa, all);

        var out: std.ArrayList(vcs.WorktreeEntry) = .empty;
        errdefer {
            for (out.items) |*entry| entry.deinit(self.gpa);
            out.deinit(self.gpa);
        }
        for (all) |entry| {
            if (!std.mem.startsWith(u8, entry.branch, "nova/")) continue;
            if (self.laneOpenAtPath(entry.path)) continue;
            const path_dup = try self.gpa.dupe(u8, entry.path);
            errdefer self.gpa.free(path_dup);
            const branch_dup = try self.gpa.dupe(u8, entry.branch);
            errdefer self.gpa.free(branch_dup);
            try out.append(self.gpa, .{ .path = path_dup, .branch = branch_dup });
        }
        return out.toOwnedSlice(self.gpa);
    }

    pub fn deleteParkedLane(self: *Workspace, entry: vcs.WorktreeEntry) void {
        const repo = self.repoRoot() orelse return;
        vcs.worktreeRemove(self.gpa, self.io, repo, entry.path) catch {};
        vcs.deleteBranch(self.gpa, self.io, repo, entry.branch) catch {};
    }

    pub fn activeLaneDirty(self: *Workspace) bool {
        const rt = self.liveRuntime() orelse return false;
        return vcs.workingTreeDirty(self.gpa, self.io, rt.cwd) catch true;
    }

    pub fn saveActiveLane(self: *Workspace, message: []const u8) !void {
        assert(message.len > 0);
        if (self.active.turn.isActive()) return Error.InFlightTurn;
        const rt = self.liveRuntime() orelse return Error.NoActiveRuntime;
        try vcs.commitAll(self.gpa, self.io, rt.cwd, message);
    }

    fn laneOpenAtPath(self: *Workspace, path: []const u8) bool {
        for (self.lanes.items) |lane| {
            if (workingLaneOf(lane)) |w| {
                if (std.mem.eql(u8, lastPathSegment(w.path), lastPathSegment(path))) return true;
            }
        }
        return false;
    }

    pub fn scheduleNaming(self: *Workspace, lane: *Thread, first_message: []const u8) !void {
        if (lane.naming_future != null) return;
        const runtime = switch (lane.engine) {
            .live => |live| live.runtime,
            .idle => return,
        };
        if (runtime.naming_client == .none) return;

        const first = try self.gpa.dupe(u8, first_message);
        errdefer self.gpa.free(first);
        const job = try self.gpa.create(naming_mod.BranchJob);
        job.* = .{
            .gpa = self.gpa,
            .client = runtime.naming_client,
            .context = lane.parent_context,
            .first_message = first,
            .done = &lane.naming_done,
        };
        lane.parent_context = &.{};
        lane.naming_done.store(false, .release);
        lane.naming_future = self.io.concurrent(naming_mod.runBranchJob, .{job}) catch |err| {
            job.deinit();
            self.gpa.destroy(job);
            return err;
        };
    }

    pub fn drainNaming(self: *Workspace) bool {
        var changed = false;
        for (self.lanes.items) |lane| {
            if (lane.naming_future == null) continue;
            if (!lane.naming_done.load(.acquire)) continue;
            var outcome = lane.naming_future.?.await(self.io);
            lane.naming_future = null;
            lane.naming_done.store(false, .release);
            defer outcome.deinit(self.gpa);
            const slug = outcome.slug orelse continue;
            if (self.renameLaneBranch(lane, slug) catch false) changed = true;
        }
        return changed;
    }

    fn renameLaneBranch(self: *Workspace, lane: *Thread, slug: []const u8) !bool {
        const live = switch (lane.engine) {
            .live => |*live| live,
            .idle => return false,
        };
        const working = switch (live.lane) {
            .working => |*w| w,
            .primary => return false,
        };

        const branch = try std.fmt.allocPrint(self.gpa, "nova/{s}", .{slug});
        errdefer self.gpa.free(branch);
        const title = try self.gpa.dupe(u8, branch);
        errdefer self.gpa.free(title);

        vcs.renameBranch(self.gpa, self.io, live.runtime.cwd, working.branch, branch) catch {
            self.gpa.free(branch);
            self.gpa.free(title);
            return false;
        };

        self.gpa.free(working.branch);
        working.branch = branch;
        // The lane's label is its branch from here on.
        if (lane.title) |old| self.gpa.free(old);
        lane.title = title;
        return true;
    }

    pub fn cancelNaming(self: *Workspace, lane: *Thread) void {
        if (lane.naming_future) |*future| {
            var outcome = future.cancel(self.io);
            outcome.deinit(self.gpa);
            lane.naming_future = null;
        }
        lane.naming_done.store(false, .release);
    }

    pub fn namingActive(self: *const Workspace) bool {
        for (self.lanes.items) |lane| {
            if (lane.naming_future != null) return true;
        }
        return false;
    }

    pub fn backgroundActive(self: *Workspace) bool {
        if (self.background_pending.items.len > 0) return true;
        const manager = self.background orelse return false;
        return manager.activeCount() > 0;
    }

    pub fn cancelBackgroundJob(self: *Workspace, id: u32) bool {
        const manager = self.background orelse return false;
        return manager.cancel(id);
    }

    pub fn pollBackgroundJobs(self: *Workspace) bool {
        const manager = self.background orelse return false;
        const finished = manager.takeFinished(self.gpa) catch return false;
        defer self.gpa.free(finished);
        for (finished) |*job| {
            defer job.deinit(self.gpa);
            const label = self.gpa.dupe(u8, job.label) catch continue;
            const command = self.gpa.dupe(u8, job.command) catch {
                self.gpa.free(label);
                continue;
            };
            // Take the model-facing message out of the job so its deinit only
            // frees the metadata.
            const message = job.completion_message;
            job.completion_message = null;
            self.background_pending.append(self.gpa, .{
                .owner = job.owner,
                .label = label,
                .command = command,
                .exit_code = job.exit_code,
                .killed = job.killed,
                .message = message,
            }) catch {
                self.gpa.free(label);
                self.gpa.free(command);
                if (message) |m| self.gpa.free(m);
            };
        }
        return finished.len > 0;
    }

    pub fn freeDelivery(self: *Workspace, delivery: *Delivery) void {
        self.gpa.free(delivery.label);
        self.gpa.free(delivery.command);
        if (delivery.message) |message| self.gpa.free(message);
        delivery.* = undefined;
    }
};

fn lastPathSegment(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

test "lastPathSegment ignores trailing separators and both slash styles" {
    try std.testing.expectEqualStrings("abc123", lastPathSegment("/home/u/.nova/worktrees/abc123"));
    try std.testing.expectEqualStrings("abc123", lastPathSegment("C:\\Users\\u\\.nova\\worktrees\\abc123\\"));
    try std.testing.expectEqualStrings("abc123", lastPathSegment("abc123"));
    try std.testing.expectEqualStrings("", lastPathSegment("/"));
}

test "workspace owns the primary lane and reports it active" {
    const gpa = std.testing.allocator;
    const primary = try gpa.create(Thread);
    primary.* = .{};
    var workspace = try Workspace.init(gpa, std.testing.io, primary);
    defer workspace.deinit();

    try std.testing.expectEqual(@as(usize, 1), workspace.lanes.items.len);
    try std.testing.expectEqual(primary, workspace.active);
    try std.testing.expectEqual(@as(usize, 0), workspace.activeIndex());
    try std.testing.expect(!workspace.anyTurnActive());
    try std.testing.expect(workspace.liveRuntime() == null);
    try std.testing.expect(workspace.repoRoot() == null);
    // No agent attached, so a checkpoint is a no-op rather than a crash.
    try std.testing.expectEqual(agent_mod.Agent.SnapshotOutcome.unavailable, workspace.checkpoint());
}

test "closing the primary lane is refused" {
    const gpa = std.testing.allocator;
    const primary = try gpa.create(Thread);
    primary.* = .{};
    var workspace = try Workspace.init(gpa, std.testing.io, primary);
    defer workspace.deinit();

    try std.testing.expectError(Error.CannotClosePrimaryLane, workspace.closeActiveLane());
    try std.testing.expectEqual(@as(usize, 1), workspace.lanes.items.len);
}

test "parking a lane drops it and lands on the previous one" {
    const gpa = std.testing.allocator;
    const primary = try gpa.create(Thread);
    primary.* = .{};
    var workspace = try Workspace.init(gpa, std.testing.io, primary);
    defer workspace.deinit();

    const second = try gpa.create(Thread);
    second.* = .{ .engine = .{ .idle = .{ .working = .{
        .branch = try gpa.dupe(u8, "nova/abc"),
        .path = try gpa.dupe(u8, "/tmp/nova/abc"),
    } } } };
    try workspace.lanes.append(gpa, second);
    workspace.active = second;
    try std.testing.expectEqual(@as(usize, 1), workspace.activeIndex());

    try workspace.closeActiveLane();
    try std.testing.expectEqual(@as(usize, 1), workspace.lanes.items.len);
    try std.testing.expectEqual(primary, workspace.active);
}
