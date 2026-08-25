//! `@`-mention parsing and message assembly.
//!
//! Two concerns live here:
//!   1. Pure parsing of `@<path>` tokens — `activeQuery` drives the live
//!      autocomplete in the TUI, `collectMentions` finds every mention in a
//!      submitted prompt.
//!   2. Assembling the message actually sent to the model — text files are
//!      embedded inline as `<file src="…">…</file>`, images are attached as
//!      real `ai.ContentBlock.image` blocks so vision models receive them via
//!      the API's image field.
//!
//! The thread still shows the raw text the user typed; only the outgoing
//! message is augmented here.
const std = @import("std");

const ai = @import("ai.zig");
const common = @import("tools/common.zig");
const image = @import("image.zig");

const assert = std.debug.assert;

/// Max bytes embedded for a text-file mention. Larger files are noted but not
/// inlined, to keep the prompt from blowing out the context window.
const max_text_bytes: usize = 256 * 1024;
/// Max bytes read for an image mention before we skip attaching it.
const max_image_bytes: usize = 5 * 1024 * 1024;

pub const Active = struct {
    /// Byte offset of the `@` within the scanned text.
    start: usize,
    /// The path fragment after `@` (may be empty when the cursor sits right
    /// after the `@`).
    query: []const u8,
};

/// The active `@`-mention token ending at the cursor, given the text *before*
/// the cursor. The token starts right after an `@` that sits at the start of
/// the text or just after whitespace, and runs to the cursor with no
/// intervening whitespace. Returns null when there is no such token (e.g. the
/// cursor is mid-word, after a space, or the `@` is embedded like an email).
pub fn activeQuery(before_cursor: []const u8) ?Active {
    var i: usize = before_cursor.len;
    while (i > 0) : (i -= 1) {
        const c = before_cursor[i - 1];
        if (isBoundary(c)) return null;
        if (c == '@') {
            const at = i - 1;
            if (at == 0 or isBoundary(before_cursor[at - 1])) {
                return .{ .start = at, .query = before_cursor[at + 1 ..] };
            }
            return null;
        }
    }
    return null;
}

/// Every distinct `@<path>` mention in `prompt`, in first-seen order. The
/// returned slices borrow from `prompt`; only the outer array is owned.
pub fn collectMentions(gpa: std.mem.Allocator, prompt: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var i: usize = 0;
    while (i < prompt.len) {
        const at_boundary = i == 0 or isBoundary(prompt[i - 1]);
        if (prompt[i] == '@' and at_boundary) {
            var j = i + 1;
            while (j < prompt.len and !isBoundary(prompt[j])) j += 1;
            const path = trimTrailingPunctuation(prompt[i + 1 .. j]);
            if (path.len > 0 and !containsPath(list.items, path)) {
                try list.append(gpa, path);
            }
            i = j;
        } else {
            i += 1;
        }
    }
    return list.toOwnedSlice(gpa);
}

/// The image mime type of the file `path` refers to, or null when it is not an
/// image. Decided by sniffing the file's header, not its extension: a path is a
/// claim and the bytes are the fact, and sending the wrong type is a provider
/// error rather than a graceful degradation.
///
/// A file that cannot be opened is not an image, so an absent `@shot.png` falls
/// through to the text path and reports the read error by name — more useful
/// than a marker for a file that is not there.
pub fn imageMime(io: std.Io, cwd: []const u8, path: []const u8) ?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = absoluteInto(&buffer, cwd, path) orelse return null;
    const kind = image.detectFile(io, .cwd(), absolute) orelse return null;
    return kind.mimeType();
}

/// Join `cwd` and `path` into `buffer` without allocating. Null when the result
/// would not fit, which for a real path means it is not worth pursuing.
fn absoluteInto(buffer: []u8, cwd: []const u8, path: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        if (path.len > buffer.len) return null;
        @memcpy(buffer[0..path.len], path);
        return buffer[0..path.len];
    }
    return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ cwd, std.fs.path.sep, path }) catch null;
}

/// `prompt` followed by an embedded `<file>` block per text mention and an
/// `<image>` marker per image mention. Used for the queued-message path (text
/// only). Caller owns the result. When there are no mentions this is just a
/// copy of `prompt`.
pub fn buildAugmentedText(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    prompt: []const u8,
) ![]u8 {
    const mentions = try collectMentions(gpa, prompt);
    defer gpa.free(mentions);
    if (mentions.len == 0) return gpa.dupe(u8, prompt);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(prompt);
    for (mentions) |path| {
        if (imageMime(io, cwd, path) != null) {
            try out.writer.print("\n\n<image src=\"{s}\" />", .{path});
            continue;
        }
        try appendFileTag(gpa, io, cwd, &out.writer, path);
    }
    return out.toOwnedSlice();
}

/// The content blocks for the outgoing user message: one text block (the
/// augmented text above), then one image block per readable image mention, then
/// one per client-supplied attachment. Caller owns the returned slice and every
/// block in it; `attached` is only borrowed and is copied here.
pub fn buildUserMessage(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    prompt: []const u8,
    attached: []const ai.ImageBlock,
) ![]ai.ContentBlock {
    const text = try buildAugmentedText(gpa, io, cwd, prompt);

    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |*block| block.deinit(gpa);
        blocks.deinit(gpa);
    }
    {
        errdefer gpa.free(text);
        try blocks.append(gpa, .{ .text = .{ .text = text } });
    }

    const mentions = try collectMentions(gpa, prompt);
    defer gpa.free(mentions);
    for (mentions) |path| {
        const mime = imageMime(io, cwd, path) orelse continue;
        const absolute = common.joinPath(gpa, cwd, path) catch continue;
        defer gpa.free(absolute);
        const bytes = common.readFileBytes(gpa, io, absolute, max_image_bytes) catch continue;
        defer gpa.free(bytes);

        const encoded = try encodeBase64(gpa, bytes);
        errdefer gpa.free(encoded);
        const mime_owned = try gpa.dupe(u8, mime);
        errdefer gpa.free(mime_owned);
        try blocks.append(gpa, .{ .image = .{ .mime_type = mime_owned, .data_base64 = encoded } });
    }

    // Attachments come after the mentions so a client that both mentions a file
    // and attaches bytes gets them in a predictable order.
    for (attached) |attachment| {
        const mime_owned = try gpa.dupe(u8, attachment.mime_type);
        errdefer gpa.free(mime_owned);
        const data_owned = try gpa.dupe(u8, attachment.data_base64);
        errdefer gpa.free(data_owned);
        try blocks.append(gpa, .{ .image = .{ .mime_type = mime_owned, .data_base64 = data_owned } });
    }
    return blocks.toOwnedSlice(gpa);
}

fn appendFileTag(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    writer: *std.Io.Writer,
    path: []const u8,
) !void {
    const absolute = common.joinPath(gpa, cwd, path) catch {
        try writer.print("\n\n<file src=\"{s}\" error=\"out of memory\"></file>", .{path});
        return;
    };
    defer gpa.free(absolute);
    const bytes = common.readFileBytes(gpa, io, absolute, max_text_bytes) catch |err| {
        const reason = if (err == error.StreamTooLong) "file too large to inline" else @errorName(err);
        try writer.print("\n\n<file src=\"{s}\" error=\"{s}\"></file>", .{ path, reason });
        return;
    };
    defer gpa.free(bytes);
    try writer.print("\n\n<file src=\"{s}\">\n{s}\n</file>", .{ path, bytes });
}

fn encodeBase64(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const buffer = try gpa.alloc(u8, encoder.calcSize(bytes.len));
    errdefer gpa.free(buffer);
    _ = encoder.encode(buffer, bytes);
    return buffer;
}

fn isBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Drops trailing sentence punctuation so `@src/x.zig.` references `src/x.zig`.
fn trimTrailingPunctuation(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0) : (end -= 1) {
        switch (path[end - 1]) {
            '.', ',', ';', ':', '!', '?' => {},
            else => break,
        }
    }
    return path[0..end];
}

fn containsPath(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

test "activeQuery detects a mention at the cursor" {
    const active = activeQuery("explain @src/ag").?;
    try std.testing.expectEqual(@as(usize, 8), active.start);
    try std.testing.expectEqualStrings("src/ag", active.query);
}

test "activeQuery handles a bare @ at the start" {
    const active = activeQuery("@").?;
    try std.testing.expectEqual(@as(usize, 0), active.start);
    try std.testing.expectEqualStrings("", active.query);
}

test "activeQuery rejects whitespace after the token" {
    try std.testing.expect(activeQuery("explain @foo ") == null);
    try std.testing.expect(activeQuery("hello world") == null);
}

test "activeQuery rejects an embedded @ (email-like)" {
    try std.testing.expect(activeQuery("mail user@host") == null);
}

test "collectMentions dedupes and strips trailing punctuation" {
    const gpa = std.testing.allocator;
    const mentions = try collectMentions(gpa, "see @src/a.zig and @src/a.zig. plus @b.png");
    defer gpa.free(mentions);
    try std.testing.expectEqual(@as(usize, 2), mentions.len);
    try std.testing.expectEqualStrings("src/a.zig", mentions[0]);
    try std.testing.expectEqualStrings("b.png", mentions[1]);
}

test "imageMime sniffs the file rather than trusting its name" {
    const io = std.testing.io;
    const dir_rel = ".zig-cache/at-mention-mime-test";
    try std.Io.Dir.createDirPath(.cwd(), io, dir_rel);
    try writeTestFile(io, dir_rel ++ "/real.png", "\x89PNG\r\n\x1a\nIHDR....");
    // Named like an image, but it is source code.
    try writeTestFile(io, dir_rel ++ "/fake.png", "const x = 1;\n");
    // An image with no extension at all is still an image.
    try writeTestFile(io, dir_rel ++ "/bare", "GIF89a" ++ ("\x00" ** 16));

    try std.testing.expectEqualStrings("image/png", imageMime(io, dir_rel, "real.png").?);
    try std.testing.expect(imageMime(io, dir_rel, "fake.png") == null);
    try std.testing.expectEqualStrings("image/gif", imageMime(io, dir_rel, "bare").?);
    try std.testing.expect(imageMime(io, dir_rel, "absent.png") == null);
}

fn writeTestFile(io: std.Io, rel_path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.createFile(.cwd(), io, rel_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

test "buildAugmentedText marks real images and reports unreadable files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const dir_rel = ".zig-cache/at-mention-aug-test";
    try std.Io.Dir.createDirPath(.cwd(), io, dir_rel);
    try writeTestFile(io, dir_rel ++ "/pic.png", "\x89PNG\r\n\x1a\nIHDR....");

    const prompt = "look @nope-xyz.txt and @" ++ dir_rel ++ "/pic.png";
    const text = try buildAugmentedText(gpa, io, cwd, prompt);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "<file src=\"nope-xyz.txt\" error=") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/pic.png\" />") != null);

    // An absent `.png` is not an image — nothing sniffed it — so it reports the
    // read error like any other missing mention instead of claiming an image.
    const absent = try buildAugmentedText(gpa, io, cwd, "and @gone-xyz.png");
    defer gpa.free(absent);
    try std.testing.expect(std.mem.indexOf(u8, absent, "<file src=\"gone-xyz.png\" error=") != null);
}

test "buildUserMessage skips unreadable images" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const blocks = try buildUserMessage(gpa, io, cwd, "hi @missing-xyz.png", &.{});
    defer {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expect(blocks[0] == .text);
}

test "buildUserMessage embeds text files and attaches images" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/at-mention-test";
    try std.Io.Dir.createDirPath(.cwd(), io, rel_dir);
    try writeTestFile(io, rel_dir ++ "/note.txt", "hello from file");
    try writeTestFile(io, rel_dir ++ "/pixel.png", "\x89PNG\r\n\x1a\n");

    const cwd = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(cwd);

    const blocks = try buildUserMessage(gpa, io, cwd, "see @note.txt and @pixel.png", &.{});
    defer {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0] == .text);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text.text, "<file src=\"note.txt\">\nhello from file\n</file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].text.text, "<image src=\"pixel.png\" />") != null);
    try std.testing.expect(blocks[1] == .image);
    try std.testing.expectEqualStrings("image/png", blocks[1].image.mime_type);
}

test "buildUserMessage with no mentions is a lone text block" {
    const gpa = std.testing.allocator;
    const blocks = try buildUserMessage(gpa, std.testing.io, ".", "plain prompt", &.{});
    defer {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("plain prompt", blocks[0].text.text);
}

test "attached images become blocks after any mentioned ones" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const attached = [_]ai.ImageBlock{.{
        .mime_type = @constCast("image/webp"),
        .data_base64 = @constCast("QUJD"),
    }};
    const blocks = try buildUserMessage(gpa, io, ".", "look at this", &attached);
    defer {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expect(blocks[0] == .text);
    try std.testing.expect(blocks[1] == .image);
    try std.testing.expectEqualStrings("image/webp", blocks[1].image.mime_type);
    try std.testing.expectEqualStrings("QUJD", blocks[1].image.data_base64);
    // Copied, not borrowed: the caller's buffers may be gone by send time.
    try std.testing.expect(blocks[1].image.data_base64.ptr != attached[0].data_base64.ptr);
}
