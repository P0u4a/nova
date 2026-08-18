//! Typed seam over git for Nova's "shadow history" — the automation layer that
//! lets a developer branch and rewind an agent's work without polluting the
//! repo. Unlike the old jj-colocated approach, git HEAD stays *attached* to the
//! user's branch and no automation commit ever lands on it:
//!
//!   - A snapshot stages the whole working tree into a **dedicated index**
//!     (never the user's `.git/index`), writes a tree, and commits it **off
//!     branch**. `git log`, `git status`, and `git branch` are untouched — the
//!     commit is reachable only through `refs/nova/*`.
//!   - Restoring a snapshot rewrites the working tree to that tree (adds,
//!     modifies, AND deletes tracked files), again without moving HEAD.
//!   - `git add -A` honors `.gitignore`, so build artifacts stay out of
//!     snapshots and are never clobbered on restore.
//!
//! ## Snapshots chain
//!
//! Each snapshot's parent is the previous snapshot on its timeline, so a
//! timeline's snapshots form a chain and its tip reaches all of them. That means
//! **one ref per timeline tip** keeps everything alive, rather than one ref per
//! snapshot — see `commitTree` and `keepRef`. The chain forks wherever the
//! conversation forks, because a new snapshot's parent is resolved from the
//! conversation's current position (`Session.snapshotAt`), not from wherever the
//! process last wrote.
//!
//! The chain connects only to itself: no branch ref ever points into it, so the
//! "HEAD stays clean" guarantee above is unaffected. The cost of chaining is that
//! an individual mid-chain snapshot can no longer be released on its own —
//! retention is per-timeline truncation, not per-entry deletion.
//!
//! The anchor between a conversation node and its code is a git **commit SHA**
//! (an `ObjectId`), stored on the session entry. Snapshots are immutable and
//! never rewritten, so the SHA always resolves — there is no need for jj's
//! rewrite-stable change-ids.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

/// Test-only. Referenced solely from `test` blocks, so a normal build never
/// analyzes it.
const git_test = @import("testing/git.zig");

pub const Error = error{BadObjectId};

/// A git object id (commit or tree), validated as lowercase hex of a git hash
/// length (40 for SHA-1, 64 for SHA-256). `parse` is the only constructor, so a
/// value of this type is a syntactically valid object id by construction.
pub const ObjectId = struct {
    bytes: [max_len]u8,
    len: u8,

    pub const max_len: u8 = 64;

    pub fn parse(raw: []const u8) Error!ObjectId {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len != 40 and trimmed.len != 64) return error.BadObjectId;
        for (trimmed) |byte| {
            const ok = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
            if (!ok) return error.BadObjectId;
        }
        var id: ObjectId = .{ .bytes = undefined, .len = @intCast(trimmed.len) };
        @memcpy(id.bytes[0..trimmed.len], trimmed);
        return id;
    }

    pub fn slice(self: *const ObjectId) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: ObjectId, other: ObjectId) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// A lane's relationship to the working tree. `.primary` is the repo's own
/// working copy (the branch Nova launched on); `.working` is a parallel lane in
/// its own `git worktree` on a dedicated branch. Lanes run in isolation, but a
/// `.working` lane can be folded back into another lane with `merge` (`/merge`
/// and `/lanes`): the source's branch is merged into the destination's worktree
/// and the source worktree is then removed.
pub const Lane = union(enum) {
    primary,
    working: Working,

    pub const Working = struct {
        /// The lane's branch, e.g. `nova/<id>`. Owned.
        branch: []u8,
        /// Absolute path to the worktree directory. Owned.
        path: []u8,
    };

    pub fn deinit(self: *Lane, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .working => |w| {
                gpa.free(w.branch);
                gpa.free(w.path);
            },
            .primary => {},
        }
        self.* = undefined;
    }

    /// The directory an agent for this lane runs tools in, or null for
    /// `.primary` (the caller uses the repo root).
    pub fn workingPath(self: *const Lane) ?[]const u8 {
        return switch (self.*) {
            .working => |w| w.path,
            .primary => null,
        };
    }
};

// ===========================================================================
// git CLI boundary
//
// Everything below shells out to `git`, funnelling stdout through `ObjectId`.
// Stateless — callers pass the working-copy directory on each call. A missing
// binary surfaces as `GitNotFound` so callers can degrade.
// ===========================================================================

pub const CmdError = error{
    GitNotFound,
    GitSpawnFailed,
    GitCommandFailed,
    GitBadOutput,
    OutOfMemory,
} || Error;

const cmd_stdout_limit: usize = 256 * 1024;
const cmd_stderr_limit: usize = 64 * 1024;
const cmd_timeout_seconds: u32 = 30;

fn cmdTimeout() std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(cmd_timeout_seconds), .clock = .awake } };
}

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: *Captured, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => 255,
    };
}

/// Run one git subcommand in `cwd`. `args` must NOT include the binary — it is
/// prepended here. `env` overrides the child environment (used to point
/// `GIT_INDEX_FILE` at the dedicated snapshot index); null inherits this
/// process's environment.
fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const []const u8,
    env: ?*const std.process.Environ.Map,
) CmdError!Captured {
    assert(cwd.len > 0);
    assert(args.len > 0);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(cmd_stdout_limit),
        .stderr_limit = .limited(cmd_stderr_limit),
        .timeout = cmdTimeout(),
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GitNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitSpawnFailed,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = termCode(result.term) };
}

/// Run a git subcommand, returning its trimmed stdout on success (code 0) or a
/// typed error. The caller owns the returned slice.
fn runOut(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const []const u8,
    env: ?*const std.process.Environ.Map,
) CmdError![]u8 {
    var out = try run(gpa, io, cwd, args, env);
    errdefer out.deinit(gpa);
    if (out.code != 0) {
        out.deinit(gpa);
        return error.GitCommandFailed;
    }
    gpa.free(out.stderr);
    return out.stdout;
}

/// True when `git` can be invoked at all.
pub fn isAvailable(gpa: std.mem.Allocator, io: std.Io) bool {
    var out = run(gpa, io, ".", &.{"--version"}, null) catch return false;
    defer out.deinit(gpa);
    return out.code == 0;
}

/// True when `dir` is inside a git working tree. Gates the snapshot feature.
pub fn isRepo(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    var out = run(gpa, io, dir, &.{ "rev-parse", "--is-inside-work-tree" }, null) catch return false;
    defer out.deinit(gpa);
    if (out.code != 0) return false;
    return std.mem.eql(u8, std.mem.trim(u8, out.stdout, " \t\r\n"), "true");
}

/// Whether the working tree of `dir` has any change versus HEAD (tracked edits
/// or new non-ignored files). Backs `/save`'s "nothing to save" guard.
pub fn workingTreeDirty(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) CmdError!bool {
    const out = try runOut(gpa, io, dir, &.{ "status", "--porcelain" }, null);
    defer gpa.free(out);
    return std.mem.trim(u8, out, " \t\r\n").len != 0;
}

/// Stage every non-ignored path and commit it onto the current branch with the
/// user's own git identity (this is a real commit they own, unlike snapshots).
/// Fails if git has no identity configured. This is all `/save` is now: HEAD is
/// attached, so committing the working tree advances the branch.
pub fn commitAll(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, message: []const u8) CmdError!void {
    assert(message.len > 0);
    {
        var out = try run(gpa, io, dir, &.{ "add", "-A" }, null);
        defer out.deinit(gpa);
        if (out.code != 0) return error.GitCommandFailed;
    }
    var out = try run(gpa, io, dir, &.{ "commit", "-m", message }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Build a child environment that inherits this process's variables and adds
/// `GIT_INDEX_FILE = index_path`, so the snapshot operations stage into the
/// dedicated index instead of the user's `.git/index`. Caller owns the map.
fn indexEnv(gpa: std.mem.Allocator, io: std.Io, index_path: []const u8) CmdError!std.process.Environ.Map {
    var map = try currentEnv(gpa, io);
    errdefer map.deinit();
    try map.put("GIT_INDEX_FILE", index_path);
    return map;
}

fn currentEnv(gpa: std.mem.Allocator, io: std.Io) CmdError!std.process.Environ.Map {
    if (builtin.os.tag == .windows) {
        return std.process.Environ.createMap(.{ .block = .global }, gpa) catch error.OutOfMemory;
    }
    _ = io;
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const line = std.mem.span(entry);
        const separator = std.mem.findScalar(u8, line, '=') orelse continue;
        if (separator == 0) continue;
        try map.put(line[0..separator], line[separator + 1 ..]);
    }
    return map;
}

/// Resolve the path of Nova's dedicated snapshot index for `dir`. Uses
/// `git rev-parse --git-path` so the location is correct for both the main
/// working copy and linked worktrees (each gets its own). Caller owns the slice.
pub fn indexPath(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) CmdError![]u8 {
    const raw = try runOut(gpa, io, dir, &.{ "rev-parse", "--git-path", "nova-index" }, null);
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.GitBadOutput;
    return gpa.dupe(u8, trimmed);
}

/// Snapshot the working tree of `dir` into an off-branch commit and return its
/// id. Stages every non-ignored path into the dedicated index (`git add -A`
/// honors `.gitignore`), writes the tree, and commits it with `parent` as its
/// only parent — null only for the first snapshot on a timeline. HEAD, the
/// user's index, and branch refs are untouched. Identical working trees produce
/// identical *tree* objects (content-addressed dedup); only the tiny commit
/// object is new. `index_path` comes from `indexPath`.
pub fn snapshot(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    index_path: []const u8,
    parent: ?ObjectId,
) CmdError!ObjectId {
    const tree = try workingTreeId(gpa, io, dir, index_path);
    return commitTree(gpa, io, dir, tree, parent);
}

/// Reconcile the dedicated index with the working tree (adds new, updates
/// modified, drops deleted — honoring `.gitignore`) and write it out as a tree
/// object, returning its id. Content-addressed, so an unchanged working tree
/// yields the *same* id — callers dedup on this to skip a no-op snapshot (the
/// "did this tool actually change anything?" check that doesn't trust output).
pub fn workingTreeId(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, index_path: []const u8) CmdError!ObjectId {
    var env = try indexEnv(gpa, io, index_path);
    defer env.deinit();
    {
        var out = try run(gpa, io, dir, &.{ "add", "-A" }, &env);
        defer out.deinit(gpa);
        if (out.code != 0) return error.GitCommandFailed;
    }
    const tree_raw = try runOut(gpa, io, dir, &.{"write-tree"}, &env);
    defer gpa.free(tree_raw);
    return ObjectId.parse(tree_raw);
}

/// Commit `tree` off-branch and return the commit id. `parent`, when given,
/// becomes the commit's only parent, chaining this snapshot onto the previous one
/// for the same timeline; null starts a fresh chain.
///
/// Chaining is what keeps the ref count down: because a snapshot reaches every
/// earlier snapshot on its timeline, one ref at the tip keeps the whole chain
/// alive, instead of one ref per snapshot. The chain is still entirely
/// off-branch — no branch ref ever points into it, so `git log`, `git status`,
/// and `git branch` stay clean.
///
/// `-c user.*` avoids depending on the user having a git identity configured
/// (snapshots are Nova's, not the user's — unlike `/save`'s real commit).
pub fn commitTree(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    tree: ObjectId,
    parent: ?ObjectId,
) CmdError!ObjectId {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "-c",          "user.name=nova",
        "-c",          "user.email=nova@local",
        "commit-tree", tree.slice(),
    });
    if (parent) |p| try argv.appendSlice(gpa, &.{ "-p", p.slice() });
    try argv.appendSlice(gpa, &.{ "-m", "nova snapshot" });

    const commit_raw = try runOut(gpa, io, dir, argv.items, null);
    defer gpa.free(commit_raw);
    return ObjectId.parse(commit_raw);
}

/// The tree a snapshot commit points at. Callers that already know a commit and
/// need its content identity use this instead of re-staging the working tree.
pub fn treeOf(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, rev: ObjectId) CmdError!ObjectId {
    const spec = std.fmt.allocPrint(gpa, "{s}^{{tree}}", .{rev.slice()}) catch return error.OutOfMemory;
    defer gpa.free(spec);
    const raw = try runOut(gpa, io, dir, &.{ "rev-parse", spec }, null);
    defer gpa.free(raw);
    return ObjectId.parse(raw);
}
/// Rewrite the working tree of `dir` to match `rev`'s tree — adding, modifying,
/// and **deleting** tracked files as needed — without moving HEAD. Ignored
/// files are left alone. Used by timeline navigation to restore the code state
/// bound to a conversation node. `index_path` comes from `indexPath`.
pub fn restore(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, index_path: []const u8, rev: ObjectId) CmdError!void {
    var env = try indexEnv(gpa, io, index_path);
    defer env.deinit();

    // Sync the dedicated index to the current working tree first, so the
    // subsequent reset knows which files to remove (those present now but absent
    // in the target tree).
    {
        var out = try run(gpa, io, dir, &.{ "add", "-A" }, &env);
        defer out.deinit(gpa);
        if (out.code != 0) return error.GitCommandFailed;
    }
    const tree_spec = std.fmt.allocPrint(gpa, "{s}^{{tree}}", .{rev.slice()}) catch return error.OutOfMemory;
    defer gpa.free(tree_spec);
    var out = try run(gpa, io, dir, &.{ "read-tree", "-u", "--reset", tree_spec }, &env);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Read the contents of `path` as it exists at `rev` (a branch name, commit, or
/// snapshot id), without touching the working tree. Backs the agent's
/// cross-branch reads. Caller owns the returned slice.
pub fn showFile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, rev: []const u8, path: []const u8) CmdError![]u8 {
    const spec = std.fmt.allocPrint(gpa, "{s}:{s}", .{ rev, path }) catch return error.OutOfMemory;
    defer gpa.free(spec);
    return runOut(gpa, io, dir, &.{ "show", spec }, null);
}

/// Create a parallel-lane worktree at `path` on a fresh `branch` forked from
/// the current HEAD of `repo_dir`. The new worktree has its own working copy,
/// branch, and (via `git rev-parse --git-path`) its own snapshot index — fully
/// isolated from the source lane.
pub fn worktreeAdd(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, path: []const u8, branch: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "worktree", "add", "-b", branch, path }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Remove a lane's worktree (and its working directory). `--force` because the
/// lane's uncommitted snapshots live off-branch, so a "dirty" worktree is normal
/// and shouldn't block teardown.
pub fn worktreeRemove(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, path: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "worktree", "remove", "--force", path }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Delete a lane's branch (best-effort; `-D` force-deletes even if unmerged).
pub fn deleteBranch(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, branch: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "branch", "-D", branch }, null);
    defer out.deinit(gpa);
    // A missing branch is fine — this is cleanup.
}

/// Rename `old` to `new` (e.g. when the model names a lane's hex branch).
/// Fails if `new` already exists; worktree HEADs checked out on `old` follow
/// the rename, so this is safe while an agent works in the lane's worktree.
pub fn renameBranch(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, old: []const u8, new: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "branch", "-m", old, new }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Outcome of a lane merge. `.conflict` covers both content conflicts and a
/// dirty destination that git refuses to overwrite — in either case the merge
/// was rolled back (`git merge --abort`) so the destination is left untouched.
pub const MergeOutcome = enum { ok, conflict };

/// Merge `branch` into the working tree of `dir` (the destination lane's
/// worktree, on its own branch). A clean merge returns `.ok`; anything git
/// refuses — content conflicts or a dirty tree it would clobber — is rolled
/// back with `git merge --abort` and returns `.conflict`, so a denied merge
/// never leaves the destination half-merged.
pub fn merge(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, branch: []const u8) CmdError!MergeOutcome {
    var out = try run(gpa, io, dir, &.{ "merge", "--no-edit", branch }, null);
    defer out.deinit(gpa);
    if (out.code == 0) return .ok;
    // Roll back so the destination worktree is exactly as it was pre-merge.
    var abort = try run(gpa, io, dir, &.{ "merge", "--abort" }, null);
    abort.deinit(gpa);
    return .conflict;
}

/// One entry from `git worktree list` — an absolute worktree `path` and the
/// `branch` checked out there (short name, e.g. `nova/<id>`). Both owned.
pub const WorktreeEntry = struct {
    path: []u8,
    branch: []u8,

    pub fn deinit(self: *WorktreeEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.branch);
        self.* = undefined;
    }
};

/// List every linked worktree of `repo_dir` and the branch each has checked out.
/// Parses `git worktree list --porcelain` (records separated by blank lines,
/// `worktree <path>` + `branch refs/heads/<name>` lines). Detached or
/// branchless worktrees are skipped. Backs `/lanes`, which filters to parked
/// `nova/*` lanes. Caller owns the slice — free with `freeWorktreeList`.
pub fn worktreeList(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8) CmdError![]WorktreeEntry {
    const raw = try runOut(gpa, io, repo_dir, &.{ "worktree", "list", "--porcelain" }, null);
    defer gpa.free(raw);

    var entries: std.ArrayList(WorktreeEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }

    var path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "worktree ")) {
            path = std.mem.trim(u8, trimmed["worktree ".len..], " \t\r");
        } else if (std.mem.startsWith(u8, trimmed, "branch ")) {
            const ref = std.mem.trim(u8, trimmed["branch ".len..], " \t\r");
            const name = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else ref;
            const p = path orelse continue;
            const path_dup = try gpa.dupe(u8, p);
            errdefer gpa.free(path_dup);
            const branch_dup = try gpa.dupe(u8, name);
            errdefer gpa.free(branch_dup);
            try entries.append(gpa, .{ .path = path_dup, .branch = branch_dup });
        }
    }
    return entries.toOwnedSlice(gpa);
}

/// Free a slice returned by `worktreeList`.
pub fn freeWorktreeList(gpa: std.mem.Allocator, entries: []WorktreeEntry) void {
    for (entries) |*entry| entry.deinit(gpa);
    gpa.free(entries);
}

/// The ref namespace that keeps snapshots alive: `refs/nova/<session>/<entry>`.
///
/// Namespaced by session because refs are repo-global while entry ids are only
/// unique within a session — two sessions in one repo would otherwise collide on
/// an 8-hex-char name and silently clobber each other's snapshots. Caller owns
/// the returned string.
fn snapshotRefName(
    gpa: std.mem.Allocator,
    session_id: []const u8,
    entry_id: []const u8,
) std.mem.Allocator.Error![]u8 {
    assert(session_id.len > 0);
    assert(entry_id.len > 0);
    return std.fmt.allocPrint(gpa, "refs/nova/{s}/{s}", .{ session_id, entry_id });
}

/// Point `refs/nova/<session_id>/<entry_id>` at `sha` so the snapshot — and,
/// because snapshots chain, every snapshot before it on this timeline — survives
/// `git gc`. Both ids must be ref-safe path segments; callers pass session and
/// entry ids, which are hex.
pub fn keepRef(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    session_id: []const u8,
    entry_id: []const u8,
    sha: ObjectId,
) CmdError!void {
    const ref = snapshotRefName(gpa, session_id, entry_id) catch return error.OutOfMemory;
    defer gpa.free(ref);
    var out = try run(gpa, io, dir, &.{ "update-ref", ref, sha.slice() }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Drop `refs/nova/<session_id>/<entry_id>`.
///
/// Safe when the snapshot it names is reachable from a newer ref — which is the
/// normal case now that snapshots chain: extending a timeline makes the previous
/// tip an ancestor of the new one, so its own ref is redundant. Otherwise the
/// objects become unreachable and a later `git gc` collects them (how an
/// abandoned timeline is pruned). A missing ref is not an error.
pub fn dropRef(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    session_id: []const u8,
    entry_id: []const u8,
) CmdError!void {
    const ref = snapshotRefName(gpa, session_id, entry_id) catch return error.OutOfMemory;
    defer gpa.free(ref);
    var out = try run(gpa, io, dir, &.{ "update-ref", "-d", ref }, null);
    defer out.deinit(gpa);
    // `update-ref -d` on a missing ref exits non-zero; treat that as success.
}

/// Delete every `refs/nova/<session_id>/*` ref, releasing that session's whole
/// snapshot chain to a later `git gc`. For discarding a session's code history
/// wholesale — an abandoned lane, a deleted session. Best-effort.
pub fn dropSessionRefs(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    session_id: []const u8,
) CmdError!void {
    assert(session_id.len > 0);
    const prefix = std.fmt.allocPrint(gpa, "refs/nova/{s}", .{session_id}) catch return error.OutOfMemory;
    defer gpa.free(prefix);
    const listing = try runOut(gpa, io, dir, &.{ "for-each-ref", "--format=%(refname)", prefix }, null);
    defer gpa.free(listing);

    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const ref = std.mem.trim(u8, line, " \t\r");
        if (ref.len == 0) continue;
        var out = try run(gpa, io, dir, &.{ "update-ref", "-d", ref }, null);
        out.deinit(gpa);
    }
}

test "ObjectId.parse accepts 40/64 lowercase hex, trims, rejects the rest" {
    const sha1 = "0123456789abcdef0123456789abcdef01234567"; // 40
    const ok = try ObjectId.parse("  " ++ sha1 ++ "\n");
    try std.testing.expectEqual(@as(u8, 40), ok.len);
    try std.testing.expectEqualStrings(sha1, ok.slice());

    _ = try ObjectId.parse("a" ** 64); // SHA-256 length
    try std.testing.expectError(error.BadObjectId, ObjectId.parse(""));
    try std.testing.expectError(error.BadObjectId, ObjectId.parse("abc")); // too short
    try std.testing.expectError(error.BadObjectId, ObjectId.parse("g" ** 40)); // non-hex
    try std.testing.expectError(error.BadObjectId, ObjectId.parse("ABCDEF" ** 7 ++ "ab")); // uppercase
}

test "ObjectId.eql compares the live slice" {
    const a = try ObjectId.parse("0" ** 40);
    const b = try ObjectId.parse("0" ** 40);
    const c = try ObjectId.parse("0" ** 39 ++ "1");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "git shadow: snapshot ignores artifacts, restore adds/deletes, HEAD stays clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!isAvailable(gpa, io)) return error.SkipZigTest;

    var repo = try git_test.TempRepo.init(gpa, io, "nova-vcstest");
    defer repo.deinit();

    const index = try repo.indexPath();
    defer gpa.free(index);

    // `.gitignore` excludes build output; write a tracked file + an ignored one.
    try repo.writeFile(".gitignore", "build/\n");
    try repo.writeFile("a.txt", "A\n");
    try repo.writeFile("build/x", "junk\n");

    const s1 = try snapshot(gpa, io, repo.path, index, null);
    // The ignored file must NOT be in the snapshot tree; the tracked one must be.
    {
        const listing = try repo.lsTree(s1.slice());
        defer gpa.free(listing);
        try std.testing.expect(std.mem.indexOf(u8, listing, "a.txt") != null);
        try std.testing.expect(std.mem.indexOf(u8, listing, "build/x") == null);
    }

    // Second snapshot: delete a.txt, add b.txt — a different tree.
    try repo.deleteFile("a.txt");
    try repo.writeFile("b.txt", "B\n");
    const s2 = try snapshot(gpa, io, repo.path, index, s1);
    try std.testing.expect(!(try treeOf(gpa, io, repo.path, s1)).eql(try treeOf(gpa, io, repo.path, s2)));

    // Restore s1, then re-snapshot the worktree: matching trees proves the
    // working copy was rewritten exactly to s1 (a.txt re-added, b.txt deleted).
    try restore(gpa, io, repo.path, index, s1);
    const after = try snapshot(gpa, io, repo.path, index, s2);
    try std.testing.expect((try treeOf(gpa, io, repo.path, after)).eql(try treeOf(gpa, io, repo.path, s1)));

    // showFile reads a path out of a snapshot without touching the worktree.
    {
        const content = try showFile(gpa, io, repo.path, s1.slice(), "a.txt");
        defer gpa.free(content);
        try std.testing.expectEqualStrings("A\n", content);
    }

    // keepRef makes a snapshot survive an aggressive gc.
    try keepRef(gpa, io, repo.path, "0" ** 32, "0badcafe", s1);
    try repo.gcPruneNow();
    try repo.expectCommitAlive(s1);

    // HEAD never moved and history stays a single commit (no snapshot pollution).
    try std.testing.expectEqual(@as(usize, 1), try repo.headCommitCount());
}

test "snapshot chain: one tip ref keeps every ancestor alive through gc" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!isAvailable(gpa, io)) return error.SkipZigTest;

    var repo = try git_test.TempRepo.init(gpa, io, "nova-chaintest");
    defer repo.deinit();

    const index = try repo.indexPath();
    defer gpa.free(index);

    const session = "1" ** 32;

    // Three snapshots, each chained onto the previous one. After each, the ref
    // moves to the new tip and the superseded one is released.
    try repo.writeFile("a.txt", "one\n");
    const s1 = try snapshot(gpa, io, repo.path, index, null);
    try keepRef(gpa, io, repo.path, session, "entry001", s1);

    try repo.writeFile("a.txt", "two\n");
    const s2 = try snapshot(gpa, io, repo.path, index, s1);
    try keepRef(gpa, io, repo.path, session, "entry002", s2);
    try dropRef(gpa, io, repo.path, session, "entry001");

    try repo.writeFile("a.txt", "three\n");
    const s3 = try snapshot(gpa, io, repo.path, index, s2);
    try keepRef(gpa, io, repo.path, session, "entry003", s3);
    try dropRef(gpa, io, repo.path, session, "entry002");

    // Exactly one ref remains for the session, at the tip.
    {
        const refs = try repo.sessionRefs(session);
        defer repo.freeRefs(refs);
        try std.testing.expectEqual(@as(usize, 1), refs.len);
        try std.testing.expectEqualStrings("refs/nova/" ++ session ++ "/entry003", refs[0]);
        try repo.expectResolvesTo(refs[0], s3.slice());
    }

    // An aggressive gc must not collect the ancestors: they are reachable from
    // the tip through the parent chain even though their own refs are gone.
    try repo.gcPruneNow();
    for ([_]ObjectId{ s1, s2, s3 }) |commit| try repo.expectCommitAlive(commit);

    // Chained commits still restore by tree, so an ancestor is a valid target.
    try restore(gpa, io, repo.path, index, s1);
    {
        const content = try showFile(gpa, io, repo.path, s1.slice(), "a.txt");
        defer gpa.free(content);
        try std.testing.expectEqualStrings("one\n", content);
    }

    // HEAD never moved: the chain is entirely off-branch.
    try std.testing.expectEqual(@as(usize, 1), try repo.headCommitCount());

    // dropSessionRefs releases the whole chain in one call.
    try dropSessionRefs(gpa, io, repo.path, session);
    try std.testing.expectEqual(@as(usize, 0), try repo.sessionRefCount(session));
}

test "worktree lanes: list finds lane branches, merge folds one in, conflict rolls back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!isAvailable(gpa, io)) return error.SkipZigTest;

    var repo = try git_test.TempRepo.init(gpa, io, "nova-mergetest");
    defer repo.deinit();

    try repo.writeFile("base.txt", "base\n");
    try repo.expectOk(&.{ "add", "-A" });
    try repo.expectOk(&.{ "commit", "-qm", "with base" });

    // Two lanes forked from HEAD (nested under the repo; git tracks them as
    // linked worktrees, not files).
    const dest = try std.fs.path.join(gpa, &.{ repo.path, "wt-dest" });
    defer gpa.free(dest);
    const src = try std.fs.path.join(gpa, &.{ repo.path, "wt-src" });
    defer gpa.free(src);
    try worktreeAdd(gpa, io, repo.path, dest, "nova/dest");
    try worktreeAdd(gpa, io, repo.path, src, "nova/src");

    // worktreeList reports both lane branches.
    {
        const list = try worktreeList(gpa, io, repo.path);
        defer freeWorktreeList(gpa, list);
        var saw_src = false;
        var saw_dest = false;
        for (list) |entry| {
            if (std.mem.eql(u8, entry.branch, "nova/src")) saw_src = true;
            if (std.mem.eql(u8, entry.branch, "nova/dest")) saw_dest = true;
        }
        try std.testing.expect(saw_src and saw_dest);
    }

    // Non-conflicting work on the source lane; commit it onto nova/src.
    try repo.writeFile("wt-src/feature.txt", "feature\n");
    try repo.expectOkIn(src, &.{ "add", "-A" });
    try repo.expectOkIn(src, &.{ "commit", "-qm", "feat" });

    // Merge folds the source lane's file into the destination worktree.
    try std.testing.expectEqual(MergeOutcome.ok, try merge(gpa, io, dest, "nova/src"));
    {
        const merged = try showFile(gpa, io, dest, "HEAD", "feature.txt");
        defer gpa.free(merged);
        try std.testing.expectEqualStrings("feature\n", merged);
    }

    // Divergent edits to the same file on each lane → conflict, rolled back.
    try repo.writeFile("wt-src/base.txt", "src-change\n");
    try repo.expectOkIn(src, &.{ "commit", "-aqm", "src edit" });
    try repo.writeFile("wt-dest/base.txt", "dest-change\n");
    try repo.expectOkIn(dest, &.{ "commit", "-aqm", "dest edit" });
    try std.testing.expectEqual(MergeOutcome.conflict, try merge(gpa, io, dest, "nova/src"));

    // The abort left the destination exactly as it was — no half-merge.
    const restored = try showFile(gpa, io, dest, "HEAD", "base.txt");
    defer gpa.free(restored);
    try std.testing.expectEqualStrings("dest-change\n", restored);
}
