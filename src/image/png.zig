//! A PNG decoder and encoder, just enough to crop and scale.
//!
//! PNG only, and deliberately so. Screenshots, rendered charts and UI captures —
//! the images a coding agent is asked to look at — are overwhelmingly PNG, and
//! PNG is a decoder we can write correctly: zlib (which `std.compress.flate`
//! already provides), five scanline filters, and a handful of pixel layouts.
//! Baseline JPEG would mean Huffman tables, an IDCT and chroma upsampling for a
//! format that mostly shows up as photographs, so `zoom` refuses it and points at
//! `bash` for a conversion rather than pretending.
//!
//! Everything decodes to RGBA8 so the rest of the pipeline has one layout to
//! think about. Interlaced (Adam7) files are refused rather than mis-decoded.

const std = @import("std");

const assert = std.debug.assert;

/// Largest image we will decode, in pixels. At RGBA8 this is 256 MiB of
/// intermediate buffer, which is already far past anything worth looking at; the
/// point is to refuse a decompression bomb rather than to try.
pub const pixels_max: u64 = 64 * 1024 * 1024;

pub const signature = "\x89PNG\r\n\x1a\n";

pub const Error = error{
    /// Not a PNG at all, or a truncated one.
    Malformed,
    /// A valid PNG using a feature this decoder does not implement.
    Unsupported,
    /// Larger than `pixels_max`.
    TooLarge,
    OutOfMemory,
};

/// A decoded image as tightly packed RGBA8, row-major from the top-left.
pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes. Owned.
    pixels: []u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    /// Byte offset of pixel (`x`, `y`). Asserts the coordinates are in bounds —
    /// callers clamp before they get here.
    pub fn offset(self: Image, x: u32, y: u32) usize {
        assert(x < self.width);
        assert(y < self.height);
        return (@as(usize, y) * self.width + x) * 4;
    }
};

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    palette = 3,
    grayscale_alpha = 4,
    rgba = 6,

    fn channels(self: ColorType) u8 {
        return switch (self) {
            .grayscale, .palette => 1,
            .grayscale_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,

    /// Bytes per filter unit: one pixel rounded up to a byte, which is what the
    /// filters operate on for sub-byte depths.
    fn filterStride(self: Header) usize {
        const bits = @as(usize, self.color_type.channels()) * self.bit_depth;
        return @max(1, bits / 8);
    }

    fn bytesPerRow(self: Header) usize {
        const bits = @as(usize, self.width) * self.color_type.channels() * self.bit_depth;
        return (bits + 7) / 8;
    }
};

pub fn is(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, signature);
}

/// Read just the dimensions out of the IHDR, without decompressing anything.
/// Lets a caller decide what to do (resize? refuse?) before paying for a decode.
pub fn dimensions(bytes: []const u8) Error!struct { width: u32, height: u32 } {
    const header = try readHeader(bytes);
    return .{ .width = header.width, .height = header.height };
}

fn readHeader(bytes: []const u8) Error!Header {
    if (!is(bytes)) return error.Malformed;
    // Signature, then the IHDR chunk: 4 length + 4 type + 13 data + 4 crc.
    if (bytes.len < signature.len + 25) return error.Malformed;
    const ihdr = bytes[signature.len..];
    if (readU32(ihdr[0..4]) != 13) return error.Malformed;
    if (!std.mem.eql(u8, ihdr[4..8], "IHDR")) return error.Malformed;
    const data = ihdr[8..21];

    const width = readU32(data[0..4]);
    const height = readU32(data[4..8]);
    if (width == 0 or height == 0) return error.Malformed;
    if (@as(u64, width) * height > pixels_max) return error.TooLarge;

    const bit_depth = data[8];
    const color_type: ColorType = switch (data[9]) {
        0 => .grayscale,
        2 => .rgb,
        3 => .palette,
        4 => .grayscale_alpha,
        6 => .rgba,
        else => return error.Malformed,
    };
    if (data[10] != 0) return error.Unsupported; // compression method
    if (data[11] != 0) return error.Unsupported; // filter method
    if (data[12] != 0) return error.Unsupported; // Adam7 interlacing

    const depth_ok = switch (color_type) {
        .grayscale => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        .palette => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        .rgb, .grayscale_alpha, .rgba => bit_depth == 8 or bit_depth == 16,
    };
    if (!depth_ok) return error.Malformed;

    const header: Header = .{ .width = width, .height = height, .bit_depth = bit_depth, .color_type = color_type };
    // Every later stage sizes buffers off these two, so they must be sane here.
    assert(header.bytesPerRow() > 0);
    assert(header.filterStride() > 0);
    return header;
}

/// Decode `bytes` to RGBA8. Caller owns the result.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Image {
    const header = try readHeader(bytes);

    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var palette_len: usize = 0;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    var saw_end = false;

    // Walk the chunk list. IDAT may be split arbitrarily, so the pieces are
    // concatenated before inflating — a zlib stream can straddle the boundary.
    var at: usize = signature.len;
    while (at + 8 <= bytes.len) {
        const length = readU32(bytes[at..][0..4]);
        const kind = bytes[at + 4 ..][0..4];
        const body_at = at + 8;
        if (length > bytes.len or body_at + length + 4 > bytes.len) return error.Malformed;
        const body = bytes[body_at..][0..length];

        if (std.mem.eql(u8, kind, "IDAT")) {
            compressed.appendSlice(gpa, body) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (length % 3 != 0 or length / 3 > 256) return error.Malformed;
            palette_len = length / 3;
            for (0..palette_len) |i| {
                palette[i] = .{ body[i * 3], body[i * 3 + 1], body[i * 3 + 2], 255 };
            }
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            // Only the palette form is handled; a colour-key on a truecolour
            // image is rare and dropping it only loses transparency.
            if (header.color_type == .palette) {
                for (body, 0..) |alpha, i| {
                    if (i >= palette.len) break;
                    palette[i][3] = alpha;
                }
            }
        } else if (std.mem.eql(u8, kind, "IEND")) {
            saw_end = true;
            break;
        }
        at = body_at + length + 4;
    }
    if (!saw_end or compressed.items.len == 0) return error.Malformed;
    if (header.color_type == .palette and palette_len == 0) return error.Malformed;

    const raw = try inflate(gpa, compressed.items, header);
    defer gpa.free(raw);

    const decoded = try expand(gpa, header, raw, &palette);
    assert(decoded.width == header.width);
    assert(decoded.height == header.height);
    assert(decoded.pixels.len == @as(usize, header.width) * header.height * 4);
    return decoded;
}

/// Inflate the IDAT stream and undo the per-scanline filters, leaving the raw
/// packed samples (one row after another, no filter bytes).
fn inflate(gpa: std.mem.Allocator, compressed: []const u8, header: Header) Error![]u8 {
    assert(compressed.len > 0);
    assert(header.height > 0);

    const row_bytes = header.bytesPerRow();
    assert(row_bytes > 0);
    const expected = (row_bytes + 1) * @as(usize, header.height);

    var source: std.Io.Reader = .fixed(compressed);
    const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
    defer gpa.free(window);
    var decompress: std.compress.flate.Decompress = .init(&source, .zlib, window);

    const filtered = gpa.alloc(u8, expected) catch return error.OutOfMemory;
    defer gpa.free(filtered);
    const read = decompress.reader.readSliceShort(filtered) catch return error.Malformed;
    if (read != expected) return error.Malformed;

    const out = gpa.alloc(u8, row_bytes * @as(usize, header.height)) catch return error.OutOfMemory;
    errdefer gpa.free(out);

    const stride = header.filterStride();
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const filter = filtered[y * (row_bytes + 1)];
        const src = filtered[y * (row_bytes + 1) + 1 ..][0..row_bytes];
        const row = out[y * row_bytes ..][0..row_bytes];
        const prev: ?[]const u8 = if (y == 0) null else out[(y - 1) * row_bytes ..][0..row_bytes];
        try unfilter(filter, src, row, prev, stride);
    }
    return out;
}

/// Reverse one scanline filter in place into `row`. Per RFC 2083: each filter
/// predicts a byte from already-reconstructed neighbours, so this must run in
/// order and `prev` must already be reconstructed.
fn unfilter(filter: u8, src: []const u8, row: []u8, prev: ?[]const u8, stride: usize) Error!void {
    assert(src.len == row.len);
    switch (filter) {
        0 => @memcpy(row, src),
        1 => for (src, 0..) |byte, i| {
            const left: u8 = if (i >= stride) row[i - stride] else 0;
            row[i] = byte +% left;
        },
        2 => for (src, 0..) |byte, i| {
            const up: u8 = if (prev) |p| p[i] else 0;
            row[i] = byte +% up;
        },
        3 => for (src, 0..) |byte, i| {
            const left: u16 = if (i >= stride) row[i - stride] else 0;
            const up: u16 = if (prev) |p| p[i] else 0;
            row[i] = byte +% @as(u8, @truncate((left + up) / 2));
        },
        4 => for (src, 0..) |byte, i| {
            const left: u8 = if (i >= stride) row[i - stride] else 0;
            const up: u8 = if (prev) |p| p[i] else 0;
            const up_left: u8 = if (prev != null and i >= stride) prev.?[i - stride] else 0;
            row[i] = byte +% paeth(left, up, up_left);
        },
        else => return error.Malformed,
    }
}

/// The Paeth predictor: whichever of left/up/upper-left is closest to their
/// linear estimate.
fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const estimate = @as(i16, left) + @as(i16, up) - @as(i16, up_left);
    const d_left = @abs(estimate - @as(i16, left));
    const d_up = @abs(estimate - @as(i16, up));
    const d_up_left = @abs(estimate - @as(i16, up_left));
    if (d_left <= d_up and d_left <= d_up_left) return left;
    if (d_up <= d_up_left) return up;
    return up_left;
}

/// Widen the packed samples to RGBA8.
fn expand(gpa: std.mem.Allocator, header: Header, raw: []const u8, palette: *const [256][4]u8) Error!Image {
    assert(raw.len == header.bytesPerRow() * header.height);

    const count = @as(usize, header.width) * header.height;
    const pixels = gpa.alloc(u8, count * 4) catch return error.OutOfMemory;
    errdefer gpa.free(pixels);

    const row_bytes = header.bytesPerRow();
    var y: u32 = 0;
    while (y < header.height) : (y += 1) {
        const row = raw[y * row_bytes ..][0..row_bytes];
        var x: u32 = 0;
        while (x < header.width) : (x += 1) {
            const out = pixels[(@as(usize, y) * header.width + x) * 4 ..][0..4];
            switch (header.color_type) {
                .palette => {
                    const index = sample(row, x, header.bit_depth, 1, 0);
                    out.* = palette[index];
                },
                .grayscale => {
                    const value = scaleTo8(sample(row, x, header.bit_depth, 1, 0), header.bit_depth);
                    out.* = .{ value, value, value, 255 };
                },
                .grayscale_alpha => {
                    const value = scaleTo8(sample(row, x, header.bit_depth, 2, 0), header.bit_depth);
                    const alpha = scaleTo8(sample(row, x, header.bit_depth, 2, 1), header.bit_depth);
                    out.* = .{ value, value, value, alpha };
                },
                .rgb => out.* = .{
                    scaleTo8(sample(row, x, header.bit_depth, 3, 0), header.bit_depth),
                    scaleTo8(sample(row, x, header.bit_depth, 3, 1), header.bit_depth),
                    scaleTo8(sample(row, x, header.bit_depth, 3, 2), header.bit_depth),
                    255,
                },
                .rgba => out.* = .{
                    scaleTo8(sample(row, x, header.bit_depth, 4, 0), header.bit_depth),
                    scaleTo8(sample(row, x, header.bit_depth, 4, 1), header.bit_depth),
                    scaleTo8(sample(row, x, header.bit_depth, 4, 2), header.bit_depth),
                    scaleTo8(sample(row, x, header.bit_depth, 4, 3), header.bit_depth),
                },
            }
        }
    }
    return .{ .width = header.width, .height = header.height, .pixels = pixels };
}

/// Read channel `channel` of pixel `x` out of a packed scanline. Sub-byte depths
/// pack several samples per byte, most significant first; 16-bit samples are
/// narrowed to their high byte, which is all the precision the rest of the
/// pipeline keeps.
fn sample(row: []const u8, x: u32, bit_depth: u8, channels: u8, channel: u8) u8 {
    assert(channel < channels);
    assert(bit_depth > 0);
    const index = @as(usize, x) * channels + channel;
    return switch (bit_depth) {
        16 => row[index * 2],
        8 => row[index],
        else => blk: {
            const per_byte = @as(usize, 8 / bit_depth);
            const byte = row[index / per_byte];
            const slot = index % per_byte;
            const shift: u3 = @intCast(8 - bit_depth * (slot + 1));
            const mask: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;
            break :blk (byte >> shift) & mask;
        },
    };
}

/// Stretch a `bit_depth`-bit sample to the full 0..255 range, so a 1-bit 1
/// becomes white rather than 1. Palette indices must not go through here.
fn scaleTo8(value: u8, bit_depth: u8) u8 {
    return switch (bit_depth) {
        16, 8 => value,
        4 => value * 17,
        2 => value * 85,
        1 => value * 255,
        else => unreachable,
    };
}

/// Encode `img` as an 8-bit RGBA PNG. Caller owns the result.
///
/// One IDAT, `up` filtering, default deflate level: the output is read once by a
/// model and thrown away, so decode simplicity beats the last few percent of
/// ratio.
pub fn encode(gpa: std.mem.Allocator, img: Image) Error![]u8 {
    assert(img.pixels.len == @as(usize, img.width) * img.height * 4);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    out.appendSlice(gpa, signature) catch return error.OutOfMemory;

    var ihdr: [13]u8 = undefined;
    writeU32(ihdr[0..4], img.width);
    writeU32(ihdr[4..8], img.height);
    ihdr[8] = 8; // bit depth
    ihdr[9] = @intFromEnum(ColorType.rgba);
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try appendChunk(gpa, &out, "IHDR", &ihdr);

    const idat = try deflateRows(gpa, img);
    defer gpa.free(idat);
    try appendChunk(gpa, &out, "IDAT", idat);
    try appendChunk(gpa, &out, "IEND", &.{});

    assert(is(out.items));
    return out.toOwnedSlice(gpa) catch error.OutOfMemory;
}

fn deflateRows(gpa: std.mem.Allocator, img: Image) Error![]u8 {
    const row_bytes = @as(usize, img.width) * 4;
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(gpa);
    filtered.ensureTotalCapacity(gpa, (row_bytes + 1) * img.height) catch return error.OutOfMemory;

    var y: usize = 0;
    while (y < img.height) : (y += 1) {
        const row = img.pixels[y * row_bytes ..][0..row_bytes];
        if (y == 0) {
            filtered.appendAssumeCapacity(0);
            filtered.appendSliceAssumeCapacity(row);
            continue;
        }
        // `up`: vertical neighbours correlate strongly in screenshots and charts,
        // and it needs no reference to the row being written.
        const prev = img.pixels[(y - 1) * row_bytes ..][0..row_bytes];
        filtered.appendAssumeCapacity(2);
        for (row, prev) |value, above| filtered.appendAssumeCapacity(value -% above);
    }

    // `flate.Compress` writes through the output buffer directly and asserts it
    // has room, so the allocating writer needs a real starting capacity.
    var compressed: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(gpa, 64 * 1024) catch return error.OutOfMemory;
    defer compressed.deinit();
    const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
    defer gpa.free(window);
    var deflate = std.compress.flate.Compress.init(
        &compressed.writer,
        window,
        .zlib,
        .default,
    ) catch return error.OutOfMemory;
    deflate.writer.writeAll(filtered.items) catch return error.OutOfMemory;
    // `finish`, not `flush`: it emits the final deflate block and the zlib
    // footer, without which a decoder hits end-of-stream looking for the
    // checksum.
    deflate.finish() catch return error.OutOfMemory;
    return gpa.dupe(u8, compressed.written()) catch error.OutOfMemory;
}

fn appendChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) Error!void {
    assert(body.len <= std.math.maxInt(u32));
    var length: [4]u8 = undefined;
    writeU32(&length, @intCast(body.len));
    out.appendSlice(gpa, &length) catch return error.OutOfMemory;
    out.appendSlice(gpa, kind) catch return error.OutOfMemory;
    out.appendSlice(gpa, body) catch return error.OutOfMemory;

    // The CRC covers the type and the body, but not the length.
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(body);
    var checksum: [4]u8 = undefined;
    writeU32(&checksum, crc.final());
    out.appendSlice(gpa, &checksum) catch return error.OutOfMemory;
}

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .big);
}

/// Build an RGBA image whose pixels are a deterministic function of position, so
/// a round trip can be checked exactly.
fn syntheticImage(gpa: std.mem.Allocator, width: u32, height: u32) !Image {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    for (0..height) |y| {
        for (0..width) |x| {
            const at = (y * width + x) * 4;
            pixels[at + 0] = @truncate(x * 7 + y);
            pixels[at + 1] = @truncate(y * 3);
            pixels[at + 2] = @truncate(x ^ y);
            pixels[at + 3] = 255;
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

test "an encoded image decodes back to the same pixels" {
    const gpa = std.testing.allocator;
    var original = try syntheticImage(gpa, 37, 19);
    defer original.deinit(gpa);

    const bytes = try encode(gpa, original);
    defer gpa.free(bytes);
    try std.testing.expect(is(bytes));

    var decoded = try decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(original.width, decoded.width);
    try std.testing.expectEqual(original.height, decoded.height);
    try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
}

test "a single-pixel image round-trips" {
    const gpa = std.testing.allocator;
    var original = try syntheticImage(gpa, 1, 1);
    defer original.deinit(gpa);
    const bytes = try encode(gpa, original);
    defer gpa.free(bytes);
    var decoded = try decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, original.pixels, decoded.pixels);
}

test "dimensions reads the header without decompressing" {
    const gpa = std.testing.allocator;
    var original = try syntheticImage(gpa, 12, 5);
    defer original.deinit(gpa);
    const bytes = try encode(gpa, original);
    defer gpa.free(bytes);

    const size = try dimensions(bytes);
    try std.testing.expectEqual(@as(u32, 12), size.width);
    try std.testing.expectEqual(@as(u32, 5), size.height);
    // Header-only, so a stream truncated right after IHDR still reports the size.
    const header_only = bytes[0 .. signature.len + 25];
    const also = try dimensions(header_only);
    try std.testing.expectEqual(@as(u32, 12), also.width);
}

test "malformed and unsupported inputs are refused, not guessed at" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Malformed, decode(gpa, "not a png"));
    try std.testing.expectError(error.Malformed, decode(gpa, signature));
    try std.testing.expectError(error.Malformed, dimensions(signature ++ "short"));

    var original = try syntheticImage(gpa, 4, 4);
    defer original.deinit(gpa);
    const bytes = try encode(gpa, original);
    defer gpa.free(bytes);

    // Flip the interlace byte: a valid PNG we decline rather than mis-decode.
    const interlaced = try gpa.dupe(u8, bytes);
    defer gpa.free(interlaced);
    interlaced[signature.len + 8 + 12] = 1;
    try std.testing.expectError(error.Unsupported, decode(gpa, interlaced));

    // Truncating the pixel data must not read past the buffer.
    try std.testing.expectError(error.Malformed, decode(gpa, bytes[0 .. bytes.len - 20]));
}

test "unfilter reverses each filter type" {
    // `sub` (1) predicts from the left, `up` (2) from the row above.
    var row: [4]u8 = undefined;
    try unfilter(1, &.{ 10, 5, 5, 5 }, &row, null, 1);
    try std.testing.expectEqualSlices(u8, &.{ 10, 15, 20, 25 }, &row);

    try unfilter(2, &.{ 1, 1, 1, 1 }, &row, &.{ 10, 20, 30, 40 }, 1);
    try std.testing.expectEqualSlices(u8, &.{ 11, 21, 31, 41 }, &row);

    try unfilter(0, &.{ 7, 8, 9, 10 }, &row, null, 1);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9, 10 }, &row);
    try std.testing.expectError(error.Malformed, unfilter(5, &.{ 0, 0, 0, 0 }, &row, null, 1));
}

test "paeth picks the neighbour closest to the linear estimate" {
    // Estimate is left + up - up_left; with all equal, left wins the tie.
    try std.testing.expectEqual(@as(u8, 10), paeth(10, 10, 10));
    try std.testing.expectEqual(@as(u8, 200), paeth(200, 10, 10));
    try std.testing.expectEqual(@as(u8, 200), paeth(10, 200, 10));
}

test "sub-byte and 16-bit samples widen to the full range" {
    // 1-bit: bits are most significant first, and 1 must become white.
    const one_bit = [_]u8{0b1010_0000};
    try std.testing.expectEqual(@as(u8, 255), scaleTo8(sample(&one_bit, 0, 1, 1, 0), 1));
    try std.testing.expectEqual(@as(u8, 0), scaleTo8(sample(&one_bit, 1, 1, 1, 0), 1));
    try std.testing.expectEqual(@as(u8, 255), scaleTo8(sample(&one_bit, 2, 1, 1, 0), 1));

    // 4-bit: 0xf is white, 0x8 is mid.
    const four_bit = [_]u8{0xf8};
    try std.testing.expectEqual(@as(u8, 255), scaleTo8(sample(&four_bit, 0, 4, 1, 0), 4));
    try std.testing.expectEqual(@as(u8, 136), scaleTo8(sample(&four_bit, 1, 4, 1, 0), 4));

    const sixteen_bit = [_]u8{ 0xab, 0xcd };
    try std.testing.expectEqual(@as(u8, 0xab), sample(&sixteen_bit, 0, 16, 1, 0));
}

test "a grayscale palette PNG decodes through the palette path" {
    const gpa = std.testing.allocator;
    // Hand-built 2x1 indexed PNG: palette [red, blue], pixels [0, 1].
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, signature);

    var ihdr: [13]u8 = undefined;
    writeU32(ihdr[0..4], 2);
    writeU32(ihdr[4..8], 1);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.palette);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &body, "IHDR", &ihdr);
    try appendChunk(gpa, &body, "PLTE", &.{ 255, 0, 0, 0, 0, 255 });

    // One scanline: filter byte 0, then the two palette indices.
    var raw: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer raw.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var deflate = try std.compress.flate.Compress.init(&raw.writer, window, .zlib, .default);
    try deflate.writer.writeAll(&.{ 0, 0, 1 });
    try deflate.finish();
    try appendChunk(gpa, &body, "IDAT", raw.written());
    try appendChunk(gpa, &body, "IEND", &.{});

    var decoded = try decode(gpa, body.items);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }, decoded.pixels);
}

/// Assemble a PNG by hand so the decoder is exercised on layouts our own encoder
/// never emits. `raw` is the already-filtered scanline data, filter byte included.
fn handBuilt(
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    raw: []const u8,
    idat_pieces: usize,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    try body.appendSlice(gpa, signature);

    var ihdr: [13]u8 = undefined;
    writeU32(ihdr[0..4], width);
    writeU32(ihdr[4..8], height);
    ihdr[8] = bit_depth;
    ihdr[9] = @intFromEnum(color_type);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &body, "IHDR", &ihdr);

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var deflate = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .default);
    try deflate.writer.writeAll(raw);
    try deflate.finish();

    // Split the zlib stream across several IDATs: legal, common in the wild, and
    // the decoder has to concatenate before inflating.
    const stream = compressed.written();
    const piece = @max(1, stream.len / idat_pieces);
    var at: usize = 0;
    while (at < stream.len) {
        const end = @min(at + piece, stream.len);
        try appendChunk(gpa, &body, "IDAT", stream[at..end]);
        at = end;
    }
    try appendChunk(gpa, &body, "IEND", &.{});
    return body.toOwnedSlice(gpa);
}

test "an RGB image with Paeth filtering decodes, gaining an opaque alpha" {
    const gpa = std.testing.allocator;
    // 3x2 RGB. Row 0 unfiltered, row 1 Paeth-filtered against it. With row 1's
    // bytes all zero, Paeth predicts from the row above, so it reproduces row 0.
    const raw = [_]u8{
        0, 10, 20, 30, 40, 50, 60, 70, 80, 90,
        4, 0,  0,  0,  0,  0,  0,  0,  0,  0,
    };
    const bytes = try handBuilt(gpa, 3, 2, 8, .rgb, &raw, 1);
    defer gpa.free(bytes);

    var decoded = try decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 3), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    // Alpha is filled in for a format that has none.
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, decoded.pixels[decoded.offset(0, 0)..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 70, 80, 90, 255 }, decoded.pixels[decoded.offset(2, 0)..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, decoded.pixels[decoded.offset(0, 1)..][0..4]);
}

test "a stream split across several IDAT chunks decodes as one" {
    const gpa = std.testing.allocator;
    // 4x1 grayscale, unfiltered.
    const raw = [_]u8{ 0, 0, 85, 170, 255 };
    const bytes = try handBuilt(gpa, 4, 1, 8, .grayscale, &raw, 5);
    defer gpa.free(bytes);

    // More than one IDAT really is present, or this proves nothing.
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "IDAT")) |found| {
        count += 1;
        at = found + 1;
    }
    try std.testing.expect(count > 1);

    var decoded = try decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, decoded.pixels[decoded.offset(0, 0)..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 170, 170, 170, 255 }, decoded.pixels[decoded.offset(2, 0)..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, decoded.pixels[decoded.offset(3, 0)..][0..4]);
}

test "grayscale with alpha and 16-bit samples both narrow to RGBA8" {
    const gpa = std.testing.allocator;
    // 2x1 grayscale+alpha, 8-bit: (value, alpha) pairs.
    {
        const raw = [_]u8{ 0, 100, 255, 200, 0 };
        const bytes = try handBuilt(gpa, 2, 1, 8, .grayscale_alpha, &raw, 1);
        defer gpa.free(bytes);
        var decoded = try decode(gpa, bytes);
        defer decoded.deinit(gpa);
        try std.testing.expectEqualSlices(u8, &.{ 100, 100, 100, 255 }, decoded.pixels[0..4]);
        try std.testing.expectEqualSlices(u8, &.{ 200, 200, 200, 0 }, decoded.pixels[4..8]);
    }
    // 1x1 RGBA at 16 bits per sample: the high byte survives.
    {
        const raw = [_]u8{ 0, 0xab, 0x11, 0xcd, 0x22, 0xef, 0x33, 0xff, 0xff };
        const bytes = try handBuilt(gpa, 1, 1, 16, .rgba, &raw, 1);
        defer gpa.free(bytes);
        var decoded = try decode(gpa, bytes);
        defer decoded.deinit(gpa);
        try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0xef, 0xff }, decoded.pixels[0..4]);
    }
}

test "a truncated zlib stream is malformed, not a partial image" {
    const gpa = std.testing.allocator;
    // Claims two rows but only supplies one.
    const raw = [_]u8{ 0, 1, 2, 3, 4 };
    const bytes = try handBuilt(gpa, 4, 2, 8, .grayscale, &raw, 1);
    defer gpa.free(bytes);
    try std.testing.expectError(error.Malformed, decode(gpa, bytes));
}
