//! Resolving a model-supplied path to something safe to open.
//!
//! A path from the model is untrusted input. Two ways it escapes the workspace:
//!
//!   1. **Traversal.** `../../.ssh/authorized_keys`, or an absolute path.
//!   2. **Symlinks.** A link *inside* the workspace pointing outside it. The path
//!      looks local, and a naive open follows it.
//!
//! `resolve` closes both. It resolves the path lexically, rejects anything that
//! lands outside the workspace root, then walks the components from the root
//! opening each directory **without following symlinks** — so a symlinked
//! directory in the middle fails rather than redirecting. It hands back an open
//! handle to the verified parent plus the final component, so the caller operates
//! relative to that handle and the checked path cannot be swapped underneath it.
//!
//! The final component is checked but not opened here: whether it should be
//! created, truncated, or read is the caller's business. It is rejected outright
//! if it is already a symlink, because following one is exactly the escape.
//!
//! Escaping the workspace is not forbidden in general — `bash` can still reach
//! anywhere, and is gated by the command classifier. It is forbidden *through the
//! file tools*, which have no gate of their own.

const std = @import("std");

const assert = std.debug.assert;

/// Deepest path a caller may target. Bounds the walk (tigerstyle) and is far past
/// any real source tree.
const components_max: usize = 64;

pub const Error = error{
    /// The path resolved outside the workspace root.
    PathOutsideWorkspace,
    /// A component of the path is a symlink. Following it could leave the
    /// workspace, so the whole path is refused.
    SymlinkNotAllowed,
    /// Empty, too deep, or otherwise unusable.
    InvalidPath,
    /// A component that must be a directory is a file.
    NotADirectory,
    /// The parent directory does not exist and the caller did not ask to create it.
    ParentMissing,
    AccessDenied,
    OutOfMemory,
    Unexpected,
};

/// A path proven to be inside the workspace, as an open parent handle plus the
/// final component. Operate on `name` relative to `parent`.
pub const Resolved = struct {
    parent: std.Io.Dir,
    /// Final component, relative to `parent`. Owned.
    name: []u8,
    /// The full resolved path, for messages. Owned.
    absolute: []u8,

    pub fn deinit(self: *Resolved, gpa: std.mem.Allocator, io: std.Io) void {
        self.parent.close(io);
        gpa.free(self.name);
        gpa.free(self.absolute);
        self.* = undefined;
    }
    /// Open the target for reading.
    ///
    /// Asking the OS not to follow a symlink here would be the belt to `resolve`'s
    /// braces, but it is unusable on Windows in Zig 0.16: `NtCreateFile` is issued
    /// with `.IO = .ASYNCHRONOUS` whenever `follow_symlinks` is false, and the file
    /// reader then panics on the first `PENDING` positional read. So the no-follow
    /// open is only requested where it works; everywhere else the symlink check
    /// `resolve` already performed is what protects this call.
    pub fn openFile(self: *const Resolved, io: std.Io) std.Io.File.OpenError!std.Io.File {
        return self.parent.openFile(io, self.name, .{
            .follow_symlinks = @import("builtin").os.tag == .windows,
            .resolve_beneath = true,
        });
    }

    /// Create or truncate the target.
    ///
    /// `createFile` has no no-follow option at all, so `resolve` having already
    /// refused a symlink at this name is what keeps this from writing through one.
    /// The remaining window is an attacker who can plant a symlink inside the
    /// workspace between that check and this call; `resolve_beneath` closes even
    /// that where the OS supports it (it is ignored on Windows).
    pub fn createFile(self: *const Resolved, io: std.Io) std.Io.File.OpenError!std.Io.File {
        return self.parent.createFile(io, self.name, .{
            .truncate = true,
            .resolve_beneath = true,
        });
    }
};

pub const Options = struct {
    /// Create missing parent directories, as `write` needs. Each one is created
    /// and then re-opened no-follow, so a racing symlink is still caught.
    create_parents: bool = false,
};

/// Resolve `requested` against `root`, verifying it stays inside and that no
/// component is a symlink. `root` must be absolute.
pub fn resolve(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    requested: []const u8,
    options: Options,
) Error!Resolved {
    assert(root.len > 0);
    if (requested.len == 0) return error.InvalidPath;

    const root_absolute = std.fs.path.resolve(gpa, &.{root}) catch return error.OutOfMemory;
    defer gpa.free(root_absolute);

    const absolute = std.fs.path.resolve(gpa, &.{ root, requested }) catch return error.OutOfMemory;
    errdefer gpa.free(absolute);
    if (!isWithin(root_absolute, absolute)) return error.PathOutsideWorkspace;
    // Equal means the caller targeted the workspace directory itself.
    if (absolute.len == root_absolute.len) return error.InvalidPath;

    const relative = std.mem.trim(u8, absolute[root_absolute.len..], "/\\");
    if (relative.len == 0) return error.InvalidPath;

    var parent = openRoot(io, root_absolute) catch |err| return mapOpenError(err);
    var parent_open = true;
    defer if (parent_open) parent.close(io);

    var walked: usize = 0;
    var components = std.mem.tokenizeAny(u8, relative, "/\\");
    var pending: ?[]const u8 = components.next();
    while (pending) |component| {
        walked += 1;
        if (walked > components_max) return error.InvalidPath;
        if (std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".")) {
            // `path.resolve` already folded these away; anything left is malformed.
            return error.InvalidPath;
        }

        const next = components.next();
        if (next == null) {
            // Final component: check it, but leave opening to the caller.
            try requireNotSymlink(io, parent, component);
            const name = try gpa.dupe(u8, component);
            parent_open = false;
            assert(name.len > 0);
            assert(isWithin(root_absolute, absolute));
            return .{ .parent = parent, .name = name, .absolute = absolute };
        }

        if (options.create_parents) {
            parent.createDir(io, component, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                error.AccessDenied => return error.AccessDenied,
                else => return error.Unexpected,
            };
        }
        try requireNotSymlink(io, parent, component);
        const child = parent.openDir(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.ParentMissing,
            error.NotDir => return error.NotADirectory,
            error.AccessDenied => return error.AccessDenied,
            else => return error.Unexpected,
        };
        parent.close(io);
        parent = child;
        pending = next;
    }
    return error.InvalidPath;
}

fn openRoot(io: std.Io, root_absolute: []const u8) !std.Io.Dir {
    assert(std.fs.path.isAbsolute(root_absolute));
    return std.Io.Dir.cwd().openDir(io, root_absolute, .{ .follow_symlinks = true });
}

/// Refuse `name` if it exists and is a symlink. A missing entry is fine — the
/// caller may be creating it.
fn requireNotSymlink(io: std.Io, dir: std.Io.Dir, name: []const u8) Error!void {
    assert(name.len > 0);
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.AccessDenied => return error.AccessDenied,
        else => return error.Unexpected,
    };
    if (stat.kind == .sym_link) return error.SymlinkNotAllowed;
}

fn mapOpenError(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.ParentMissing,
        error.AccessDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// Whether `candidate` is `root` or sits beneath it. Compares whole components,
/// so `/a/b` does not contain `/a/bc`. Case-insensitive on Windows, where paths
/// are.
pub fn isWithin(root: []const u8, candidate: []const u8) bool {
    assert(root.len > 0);
    if (candidate.len < root.len) return false;
    if (!pathEql(root, candidate[0..root.len])) return false;
    if (candidate.len == root.len) return true;
    // A root of `/` already ends in a separator; otherwise the next byte must be
    // one, or `/a/bc` would look like it sits under `/a/b`.
    if (isSep(root[root.len - 1])) return true;
    return isSep(candidate[root.len]);
}

fn pathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (@import("builtin").os.tag != .windows) return std.mem.eql(u8, a, b);
    for (a, b) |left, right| {
        const l = if (isSep(left)) '/' else std.ascii.toLower(left);
        const r = if (isSep(right)) '/' else std.ascii.toLower(right);
        if (l != r) return false;
    }
    return true;
}

fn isSep(byte: u8) bool {
    if (byte == '/') return true;
    return @import("builtin").os.tag == .windows and byte == '\\';
}

/// Model-facing explanation. Says what to do differently rather than just naming
/// the error.
pub fn describe(err: Error, tool: []const u8, path: []const u8, buffer: []u8) []const u8 {
    assert(tool.len > 0);
    assert(buffer.len > 0);
    const text = switch (err) {
        error.PathOutsideWorkspace => "resolves outside the workspace. File tools only reach inside the project; use bash if you genuinely need an outside path.",
        error.SymlinkNotAllowed => "goes through a symbolic link, which is refused because it can point outside the workspace. Target the real path instead.",
        error.ParentMissing => "has no such parent directory.",
        error.NotADirectory => "treats a file as a directory.",
        error.AccessDenied => "cannot be accessed: permission denied.",
        error.InvalidPath => "is not a usable path.",
        error.OutOfMemory, error.Unexpected => "could not be resolved.",
    };
    return std.fmt.bufPrint(buffer, "{s} {s}: that path {s}", .{ tool, path, text }) catch text;
}

test "isWithin matches whole components only" {
    try std.testing.expect(isWithin("/work", "/work"));
    try std.testing.expect(isWithin("/work", "/work/src/main.zig"));
    // The classic prefix bug: a sibling directory sharing a name prefix.
    try std.testing.expect(!isWithin("/work", "/workspace/secret"));
    try std.testing.expect(!isWithin("/work", "/etc/passwd"));
    try std.testing.expect(!isWithin("/work/src", "/work"));
    // A root that already ends in a separator still matches its children.
    try std.testing.expect(isWithin("/", "/etc"));
}

/// Build a throwaway workspace under the cache dir and hand back its absolute
/// path. Caller frees.
fn tempWorkspace(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const relative = try std.fs.path.join(gpa, &.{ ".zig-cache", name });
    defer gpa.free(relative);
    std.Io.Dir.cwd().deleteTree(io, relative) catch {};
    try std.Io.Dir.createDirPath(.cwd(), io, relative);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, relative });
}

test "a relative path inside the workspace resolves to its parent and name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-inside");
    defer gpa.free(root);

    var resolved = try resolve(gpa, io, root, "src/deep/file.zig", .{ .create_parents = true });
    defer resolved.deinit(gpa, io);
    try std.testing.expectEqualStrings("file.zig", resolved.name);
    try std.testing.expect(isWithin(root, resolved.absolute));

    // The returned handle is the verified parent, so writing through it lands in
    // the directory the walk checked.
    {
        var file = try resolved.createFile(io);
        defer file.close(io);
        try file.writeStreamingAll(io, "ok\n");
    }
    const check = try std.fs.path.join(gpa, &.{ ".zig-cache", "wp-inside", "src", "deep", "file.zig" });
    defer gpa.free(check);
    var opened = try std.Io.Dir.cwd().openFile(io, check, .{});
    defer opened.close(io);
    var reader = opened.reader(io, &.{});
    const content = try reader.interface.allocRemaining(gpa, .limited(64));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("ok\n", content);
}

test "traversal out of the workspace is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-traversal");
    defer gpa.free(root);

    for ([_][]const u8{
        "../escape.txt",
        "src/../../escape.txt",
        "a/b/../../../escape.txt",
    }) |attempt| {
        try std.testing.expectError(
            error.PathOutsideWorkspace,
            resolve(gpa, io, root, attempt, .{}),
        );
    }
}

test "an absolute path outside the workspace is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-absolute");
    defer gpa.free(root);

    const outside = if (@import("builtin").os.tag == .windows)
        "C:\\Windows\\System32\\drivers\\etc\\hosts"
    else
        "/etc/passwd";
    try std.testing.expectError(
        error.PathOutsideWorkspace,
        resolve(gpa, io, root, outside, .{}),
    );
}

test "an absolute path inside the workspace is accepted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-abs-inside");
    defer gpa.free(root);

    const inside = try std.fs.path.join(gpa, &.{ root, "notes.md" });
    defer gpa.free(inside);
    var resolved = try resolve(gpa, io, root, inside, .{});
    defer resolved.deinit(gpa, io);
    try std.testing.expectEqualStrings("notes.md", resolved.name);
}

test "targeting the workspace directory itself is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-self");
    defer gpa.free(root);

    try std.testing.expectError(error.InvalidPath, resolve(gpa, io, root, ".", .{}));
    try std.testing.expectError(error.InvalidPath, resolve(gpa, io, root, root, .{}));
}

/// Create a symlink, or skip the test where the platform will not allow it
/// (Windows without Developer Mode or elevation).
fn symlinkOrSkip(io: std.Io, target: []const u8, link_relative: []const u8) !void {
    std.Io.Dir.cwd().symLink(io, target, link_relative, .{}) catch return error.SkipZigTest;
}

test "a symlinked final component is refused rather than followed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-link-file");
    defer gpa.free(root);

    // A link inside the workspace pointing at something outside it: the path
    // looks local, so only the symlink check catches it.
    const outside_target = if (@import("builtin").os.tag == .windows) "C:\\Windows\\win.ini" else "/etc/passwd";
    const link = try std.fs.path.join(gpa, &.{ ".zig-cache", "wp-link-file", "innocent.txt" });
    defer gpa.free(link);
    try symlinkOrSkip(io, outside_target, link);

    try std.testing.expectError(
        error.SymlinkNotAllowed,
        resolve(gpa, io, root, "innocent.txt", .{}),
    );
}

test "a symlinked parent directory is refused rather than traversed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-link-dir");
    defer gpa.free(root);
    // A throwaway directory rather than a real system path: the point is only
    // that it sits outside `root`, and a disposable target keeps the cleanup
    // below from ever reaching through the link into anything that matters.
    const outside = try tempWorkspace(gpa, io, "wp-link-outside");
    defer gpa.free(outside);

    const link = try std.fs.path.join(gpa, &.{ ".zig-cache", "wp-link-dir", "vendor" });
    defer gpa.free(link);
    try directoryLinkOrSkip(gpa, io, outside, link);
    // Leave no reparse point behind for the next run.
    defer std.Io.Dir.cwd().deleteTree(io, link) catch {};

    // Without the stat check this resolves to a real path outside the workspace.
    // On Windows `openDir` with `follow_symlinks = false` traverses a junction
    // regardless, so the explicit check is the only thing that catches it.
    try std.testing.expectError(
        error.SymlinkNotAllowed,
        resolve(gpa, io, root, "vendor/passwd", .{}),
    );
    // Creating parents must not paper over it either.
    try std.testing.expectError(
        error.SymlinkNotAllowed,
        resolve(gpa, io, root, "vendor/sub/new.txt", .{ .create_parents = true }),
    );
}

test "a missing parent is reported as missing, not created, unless asked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try tempWorkspace(gpa, io, "wp-missing");
    defer gpa.free(root);

    try std.testing.expectError(
        error.ParentMissing,
        resolve(gpa, io, root, "nope/file.txt", .{}),
    );
    var resolved = try resolve(gpa, io, root, "nope/file.txt", .{ .create_parents = true });
    defer resolved.deinit(gpa, io);
    try std.testing.expectEqualStrings("file.txt", resolved.name);
}

test "describe names the offending path and what to do instead" {
    var buffer: [256]u8 = undefined;
    const message = describe(error.PathOutsideWorkspace, "write", "../x", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, message, "../x") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "bash") != null);
}

/// Create a link to a directory, preferring a real symlink and falling back to a
/// Windows junction — which needs no privilege, so the directory-escape defense
/// is exercised on Windows too. Skips only if neither is available.
fn directoryLinkOrSkip(gpa: std.mem.Allocator, io: std.Io, target: []const u8, link_relative: []const u8) !void {
    if (std.Io.Dir.cwd().symLink(io, target, link_relative, .{ .is_directory = true })) |_| return else |_| {}
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    // A Windows directory symlink is created in two steps — make the directory,
    // then set the reparse point — so the attempt above left an empty directory
    // behind when the second step was denied. `mklink` would then fail with
    // "already exists", and the leftover would make the next run look like a
    // pass through a plain directory.
    std.Io.Dir.cwd().deleteTree(io, link_relative) catch {};

    // `mklink` is a cmd builtin and parses `/` as the start of a switch, so a
    // forward-slash path becomes "Invalid switch". Both operands need native
    // separators. Separate argv tokens too, not one quoted string, because
    // `cmd /c "…"` re-parses its argument.
    const link_native = try nativeSeparators(gpa, link_relative);
    defer gpa.free(link_native);
    const target_native = try nativeSeparators(gpa, target);
    defer gpa.free(target_native);

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "cmd", "/c", "mklink", "/J", link_native, target_native },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.SkipZigTest;
}

fn nativeSeparators(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const copy = try gpa.dupe(u8, path);
    for (copy) |*byte| if (byte.* == '/') {
        byte.* = std.fs.path.sep;
    };
    return copy;
}
