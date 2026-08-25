//! Recognising image bytes, and packaging them for the model.
//!
//! Sniffing goes by the file's own header, not its extension: a path is a claim
//! and the bytes are the fact, and `screenshot.png` that is really a JPEG would
//! be sent with the wrong type and rejected by the provider.
//!
//! `view` decides what actually gets sent. A PNG over `raster.view_edge_max` on
//! its long edge is shrunk here rather than left for the provider to shrink
//! invisibly, because `zoom` needs the model and Nova to agree on what
//! "pixel (400, 300)" means. Formats we cannot decode go out untouched, and
//! `zoom` refuses them.

const std = @import("std");

const assert = std.debug.assert;

pub const png = @import("image/png.zig");
pub const raster = @import("image/raster.zig");

/// Largest image attached, measured on the raw bytes. An oversized image is not
/// a one-off cost — it lands in history and is re-sent with every later request —
/// so anything still past this after the view resize is refused rather than
/// silently inflating every subsequent prompt.
pub const bytes_max: usize = 5 * 1024 * 1024;

/// Enough of a header to identify every format below. BMP needs the most.
const sniff_bytes: usize = 32;

/// Formats vision models generally accept. Gated on what we can identify from a
/// header, not on what a provider might tolerate.
pub const Kind = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,

    pub fn mimeType(self: Kind) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .bmp => "image/bmp",
        };
    }
};

/// The format `bytes` actually is, or null when the header matches nothing we
/// recognise. Only the first `sniff_bytes` are examined, so a partial read is
/// enough.
pub fn detect(bytes: []const u8) ?Kind {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    // JPEG: SOI followed by any marker. The 0xff 0xd8 0xff prefix is shared with
    // JPEG 2000 codestreams, which vision APIs do not accept, so the fourth byte
    // has to be a normal marker rather than 0xf7.
    if (bytes.len >= 4 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) {
        return if (bytes[3] == 0xf7) null else .jpeg;
    }
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    // WebP is a RIFF container; the form type at offset 8 is what makes it WebP.
    if (std.mem.startsWith(u8, bytes, "RIFF") and bytes.len >= 12 and
        std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    // "BM" alone is only two bytes, so require enough header to also carry the
    // size field — a two-byte text file must not read as a bitmap.
    if (std.mem.startsWith(u8, bytes, "BM") and bytes.len >= 6) return .bmp;
    return null;
}

/// Read just enough of `path` to identify it, without loading the whole file.
/// Returns null for a non-image or an unreadable file — the caller decides
/// whether that is an error.
pub fn detectFile(io: std.Io, dir: std.Io.Dir, path: []const u8) ?Kind {
    assert(path.len > 0);
    var file = dir.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [sniff_bytes]u8 = undefined;
    var reader = file.reader(io, &.{});
    const read = reader.interface.readSliceShort(&buffer) catch return null;
    return detect(buffer[0..read]);
}

/// Base64 of `bytes`. Caller owns the result.
pub fn encodeBase64(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const buffer = try gpa.alloc(u8, encoder.calcSize(bytes.len));
    errdefer gpa.free(buffer);
    _ = encoder.encode(buffer, bytes);
    // Base64 never shrinks, and a decoder reading a short buffer would silently
    // truncate the image.
    assert(buffer.len >= bytes.len);
    return buffer;
}
/// What to send for one image file, and the dimensions it is being sent at.
pub const View = struct {
    kind: Kind,
    /// Bytes to attach, base64 not yet applied. Owned when `owned` is set;
    /// otherwise it aliases the caller's buffer.
    bytes: []const u8,
    owned: bool,
    /// Size of what the model will see. Coordinates a model reports are in this
    /// space, which is why it gets told these numbers.
    width: u32,
    height: u32,
    /// Size of the file on disk. Differs from the above when the view was shrunk.
    source_width: u32,
    source_height: u32,

    pub fn resized(self: View) bool {
        return self.width != self.source_width or self.height != self.source_height;
    }

    /// Whether a region of this image can be cropped out: the format is one we
    /// decode, and its header actually parsed. Both `zoom` and the observation
    /// text key off this, so they cannot disagree.
    pub fn zoomable(self: View) bool {
        return self.kind == .png and self.width > 0;
    }

    pub fn deinit(self: *View, gpa: std.mem.Allocator) void {
        if (self.owned) gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Decide what to send for `bytes`, shrinking an oversized PNG to the view size.
///
/// `bytes` stays borrowed when no resize was needed, so the common case of an
/// already-small screenshot costs nothing. Returns null when the bytes are not a
/// recognised image.
pub fn view(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?View {
    const kind = detect(bytes) orelse return null;

    // Start from "send it as-is, promise no dimensions", then narrow. Only PNG
    // has pixels we can decode, so only PNG can be measured or resized; every
    // other format keeps this shape.
    var result: View = .{
        .kind = kind,
        .bytes = bytes,
        .owned = false,
        .width = 0,
        .height = 0,
        .source_width = 0,
        .source_height = 0,
    };
    if (kind != .png) return result;

    // A header we cannot parse is still worth showing, just not zoomable.
    const source = png.dimensions(bytes) catch return result;
    result.width = source.width;
    result.height = source.height;
    result.source_width = source.width;
    result.source_height = source.height;
    assert(result.zoomable());

    const target = raster.viewSize(source.width, source.height);
    if (std.meta.eql(target, raster.Size{ .width = source.width, .height = source.height })) return result;

    // Decoding can still fail on a file whose header was fine. Send the original;
    // `zoom` will fail the same way and say so.
    const shrunk = shrink(gpa, bytes, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return result,
    };
    result.bytes = shrunk;
    result.owned = true;
    result.width = target.width;
    result.height = target.height;

    assert(result.resized());
    assert(result.width <= result.source_width);
    assert(result.height <= result.source_height);
    return result;
}

fn shrink(gpa: std.mem.Allocator, bytes: []const u8, target: raster.Size) ![]u8 {
    assert(target.width > 0);
    assert(target.height > 0);
    var decoded = try png.decode(gpa, bytes);
    defer decoded.deinit(gpa);
    var scaled = try raster.resize(gpa, decoded, target);
    defer scaled.deinit(gpa);
    return png.encode(gpa, scaled);
}

test "detect identifies each supported format from its header" {
    try std.testing.expectEqual(Kind.png, detect("\x89PNG\r\n\x1a\n" ++ "IHDR").?);
    try std.testing.expectEqual(Kind.jpeg, detect("\xff\xd8\xff\xe0" ++ "JFIF").?);
    try std.testing.expectEqual(Kind.gif, detect("GIF89a....").?);
    try std.testing.expectEqual(Kind.webp, detect("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expectEqual(Kind.bmp, detect("BM\x36\x00\x00\x00").?);
}

test "detect refuses things that only look like images" {
    // A JPEG 2000 codestream shares JPEG's first three bytes.
    try std.testing.expect(detect("\xff\xd8\xff\xf7rest") == null);
    // RIFF without the WEBP form type is some other container (e.g. a WAV).
    try std.testing.expect(detect("RIFF\x00\x00\x00\x00WAVEfmt ") == null);
    try std.testing.expect(detect("#!/bin/sh\n") == null);
    try std.testing.expect(detect("") == null);
    // Truncated headers must not read past the slice.
    try std.testing.expect(detect("\x89PN") == null);
    try std.testing.expect(detect("BM") == null);
    try std.testing.expect(detect("RIFF") == null);
}

test "mime types match what the APIs expect" {
    try std.testing.expectEqualStrings("image/png", Kind.png.mimeType());
    try std.testing.expectEqualStrings("image/jpeg", Kind.jpeg.mimeType());
    try std.testing.expectEqualStrings("image/webp", Kind.webp.mimeType());
}

test "detectFile sniffs bytes rather than trusting the extension" {
    const io = std.testing.io;
    const dir_rel = ".zig-cache/image-detect-test";
    try std.Io.Dir.createDirPath(.cwd(), io, dir_rel);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_rel, .{});
    defer dir.close(io);

    // A GIF wearing a .png extension is still a GIF.
    {
        var file = try dir.createFile(io, "lies.png", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "GIF89a" ++ ("\x00" ** 16));
    }
    try std.testing.expectEqual(Kind.gif, detectFile(io, dir, "lies.png").?);

    {
        var file = try dir.createFile(io, "notes.txt", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "just text\n");
    }
    try std.testing.expect(detectFile(io, dir, "notes.txt") == null);
    try std.testing.expect(detectFile(io, dir, "absent.png") == null);

    // A file shorter than the sniff window must not be over-read.
    {
        var file = try dir.createFile(io, "tiny", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "BM");
    }
    try std.testing.expect(detectFile(io, dir, "tiny") == null);
}

test "encodeBase64 round-trips" {
    const gpa = std.testing.allocator;
    const encoded = try encodeBase64(gpa, "hello");
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings("aGVsbG8=", encoded);
}

test "view leaves a small PNG untouched and reports its true size" {
    const gpa = std.testing.allocator;
    var source: png.Image = .{
        .width = 60,
        .height = 40,
        .pixels = try gpa.alloc(u8, 60 * 40 * 4),
    };
    defer source.deinit(gpa);
    @memset(source.pixels, 200);
    const bytes = try png.encode(gpa, source);
    defer gpa.free(bytes);

    var v = (try view(gpa, bytes)).?;
    defer v.deinit(gpa);
    try std.testing.expectEqual(Kind.png, v.kind);
    try std.testing.expectEqual(@as(u32, 60), v.width);
    try std.testing.expectEqual(@as(u32, 40), v.height);
    try std.testing.expect(!v.resized());
    try std.testing.expect(v.zoomable());
    // Borrowed, not copied: the common case must not duplicate the file.
    try std.testing.expect(!v.owned);
    try std.testing.expectEqual(bytes.ptr, v.bytes.ptr);
}

test "view shrinks an oversized PNG to the view cap" {
    const gpa = std.testing.allocator;
    const width = raster.view_edge_max * 2;
    var source: png.Image = .{
        .width = width,
        .height = 100,
        .pixels = try gpa.alloc(u8, @as(usize, width) * 100 * 4),
    };
    defer source.deinit(gpa);
    @memset(source.pixels, 90);
    const bytes = try png.encode(gpa, source);
    defer gpa.free(bytes);

    var v = (try view(gpa, bytes)).?;
    defer v.deinit(gpa);
    try std.testing.expectEqual(raster.view_edge_max, v.width);
    try std.testing.expectEqual(@as(u32, 50), v.height);
    try std.testing.expectEqual(width, v.source_width);
    try std.testing.expect(v.resized());
    try std.testing.expect(v.owned);
    // The attached bytes really are the smaller image.
    const sent = try png.dimensions(v.bytes);
    try std.testing.expectEqual(raster.view_edge_max, sent.width);
}

test "view passes an undecodable format through without claiming dimensions" {
    const gpa = std.testing.allocator;
    const gif = "GIF89a" ++ ("\x00" ** 16);
    var v = (try view(gpa, gif)).?;
    defer v.deinit(gpa);
    try std.testing.expectEqual(Kind.gif, v.kind);
    try std.testing.expect(!v.zoomable());
    try std.testing.expectEqual(@as(u32, 0), v.width);
    try std.testing.expect(!v.owned);

    // A PNG signature with a garbage header is also not zoomable, but is still
    // worth showing.
    const broken = png.signature ++ ("\x00" ** 40);
    var bad = (try view(gpa, broken)).?;
    defer bad.deinit(gpa);
    try std.testing.expectEqual(Kind.png, bad.kind);
    try std.testing.expect(!bad.zoomable());

    try std.testing.expect((try view(gpa, "plain text")) == null);
}
