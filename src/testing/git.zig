//! Test-only support for the git-backed suites
const std = @import("std");

const vcs = @import("../vcs.zig");

/// A git repository in a uniquely-named directory under the process cwd, with a
/// committed baseline so HEAD is attached to a branch. `deinit` removes it.
///
/// Tests hold this by value and reach `repo.path` for absolute-path APIs or
/// `repo.name` for cwd-relative file writes.
pub const TempRepo = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// cwd-relative directory name, unique per instance.
    name: []u8,
    /// Absolute path to the repository root.
    path: []u8,

    /// Create the repo. `prefix` names it (`<prefix>-<random hex>`) so a failed
    /// run leaves an identifiable directory behind.
    ///
    /// Configures a git identity, because worktree commits and `/save` need one,
    /// and disables autocrlf so content round-trips byte-for-byte on Windows.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, prefix: []const u8) !TempRepo {
        var rand: [8]u8 = undefined;
        io.random(&rand);
        const hex = std.fmt.bytesToHex(rand, .lower);
        const name = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ prefix, hex[0..] });
        errdefer gpa.free(name);
        try std.Io.Dir.cwd().createDirPath(io, name);
        errdefer std.Io.Dir.cwd().deleteTree(io, name) catch {};

        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        const path = try std.fs.path.join(gpa, &.{ cwd, name });
        errdefer gpa.free(path);

        var repo: TempRepo = .{ .gpa = gpa, .io = io, .name = name, .path = path };
        try repo.expectOk(&.{ "init", "-q" });
        try repo.expectOk(&.{ "config", "core.autocrlf", "false" });
        try repo.expectOk(&.{ "config", "user.name", "t" });
        try repo.expectOk(&.{ "config", "user.email", "t@t" });
        try repo.expectOk(&.{ "commit", "--allow-empty", "-qm", "baseline" });
        return repo;
    }

    pub fn deinit(self: *TempRepo) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.name) catch {};
        self.gpa.free(self.name);
        self.gpa.free(self.path);
        self.* = undefined;
    }

    pub fn indexPath(self: *TempRepo) ![]u8 {
        return vcs.indexPath(self.gpa, self.io, self.path);
    }

    pub fn run(self: *TempRepo, args: []const []const u8) !std.process.RunResult {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, "git");
        try argv.appendSlice(self.gpa, args);
        return std.process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.path },
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
    }

    pub fn expectOk(self: *TempRepo, args: []const []const u8) !void {
        return self.expectOkIn(self.path, args);
    }

    pub fn expectOkIn(self: *TempRepo, dir: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, "git");
        try argv.appendSlice(self.gpa, args);
        const result = try std.process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = dir },
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    }

    pub fn out(self: *TempRepo, args: []const []const u8) ![]u8 {
        const result = try self.run(args);
        errdefer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        const owned = try self.gpa.dupe(u8, trimmed);
        self.gpa.free(result.stdout);
        return owned;
    }

    pub fn writeFile(self: *TempRepo, rel: []const u8, content: []const u8) !void {
        const full = try std.fs.path.join(self.gpa, &.{ self.name, rel });
        defer self.gpa.free(full);
        if (std.fs.path.dirname(rel)) |sub| {
            const dir = try std.fs.path.join(self.gpa, &.{ self.name, sub });
            defer self.gpa.free(dir);
            try std.Io.Dir.cwd().createDirPath(self.io, dir);
        }
        var file = try std.Io.Dir.createFile(.cwd(), self.io, full, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, content);
    }

    pub fn deleteFile(self: *TempRepo, rel: []const u8) !void {
        const full = try std.fs.path.join(self.gpa, &.{ self.name, rel });
        defer self.gpa.free(full);
        try std.Io.Dir.cwd().deleteFile(self.io, full);
    }

    pub fn revListCount(self: *TempRepo, rev: []const u8) !usize {
        const raw = try self.out(&.{ "rev-list", "--count", rev });
        defer self.gpa.free(raw);
        return std.fmt.parseInt(usize, raw, 10);
    }

    pub fn revParse(self: *TempRepo, rev: []const u8) ![]u8 {
        return self.out(&.{ "rev-parse", rev });
    }

    pub fn expectResolvesTo(self: *TempRepo, rev: []const u8, expected: []const u8) !void {
        const actual = try self.revParse(rev);
        defer self.gpa.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }

    pub fn expectCommitAlive(self: *TempRepo, commit: vcs.ObjectId) !void {
        const kind = try self.out(&.{ "cat-file", "-t", commit.slice() });
        defer self.gpa.free(kind);
        try std.testing.expectEqualStrings("commit", kind);
    }

    pub fn lsTree(self: *TempRepo, rev: []const u8) ![]u8 {
        return self.out(&.{ "ls-tree", "-r", "--name-only", rev });
    }

    pub fn headCommitCount(self: *TempRepo) !usize {
        return self.revListCount("HEAD");
    }

    pub fn gcPruneNow(self: *TempRepo) !void {
        return self.expectOk(&.{ "gc", "--prune=now", "-q" });
    }

    pub fn refsUnder(self: *TempRepo, prefix: []const u8) ![][]u8 {
        const listing = try self.out(&.{ "for-each-ref", "--format=%(refname)", prefix });
        defer self.gpa.free(listing);

        var refs: std.ArrayList([]u8) = .empty;
        errdefer {
            for (refs.items) |ref| self.gpa.free(ref);
            refs.deinit(self.gpa);
        }
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const ref = std.mem.trim(u8, line, " \t\r");
            if (ref.len == 0) continue;
            try refs.append(self.gpa, try self.gpa.dupe(u8, ref));
        }
        return refs.toOwnedSlice(self.gpa);
    }

    pub fn freeRefs(self: *TempRepo, refs: [][]u8) void {
        for (refs) |ref| self.gpa.free(ref);
        self.gpa.free(refs);
    }

    pub fn sessionRefs(self: *TempRepo, session_id: []const u8) ![][]u8 {
        const prefix = try std.fmt.allocPrint(self.gpa, "refs/nova/{s}", .{session_id});
        defer self.gpa.free(prefix);
        return self.refsUnder(prefix);
    }

    pub fn sessionRefCount(self: *TempRepo, session_id: []const u8) !usize {
        const refs = try self.sessionRefs(session_id);
        defer self.freeRefs(refs);
        return refs.len;
    }
};
