//! Cropping and scaling RGBA8 images.
//!
//! Two operations with different needs. Shrinking for the view averages every
//! source pixel that lands in a destination pixel — a box filter — because
//! point-sampling a downscale drops whole rows of thin chart lines and small
//! text. Magnifying a crop interpolates bilinearly: nearest-neighbour keeps
//! edges crisp but turns antialiased glyphs into blocks, which is worse to read.
//!
//! Neither is a Lanczos kernel. That costs more code and more time for a
//! difference the model is unlikely to notice at these scale factors.

const std = @import("std");

const png = @import("png.zig");

const assert = std.debug.assert;

/// Longest edge, in pixels, of an image sent to a model.
///
/// Providers downscale above their own limits anyway, and a larger image buys no
/// detail while costing tokens. Sizing here rather than letting the provider do
/// it invisibly is what makes `zoom` coordinates meaningful: the model is told
/// the exact dimensions it is looking at, so the box it names maps onto our copy
/// without a scale factor it has to guess.
pub const view_edge_max: u32 = 1568;

/// Ceiling on how much a crop is magnified. Without it, zooming a 3x3 region
/// would produce a 1568x1568 image of nine enormous squares — all budget, no
/// information.
pub const zoom_scale_max: u32 = 16;

pub const Size = struct { width: u32, height: u32 };

/// The size an image is sent at: unchanged when it already fits, otherwise
/// shrunk to `view_edge_max` on its longest edge with the aspect ratio kept.
///
/// Deterministic, so `zoom` can recompute the exact view the model was shown
/// from the file alone — no state carried between calls.
pub fn viewSize(width: u32, height: u32) Size {
    assert(width > 0);
    assert(height > 0);

    const longest = @max(width, height);
    const size: Size = if (longest <= view_edge_max)
        .{ .width = width, .height = height }
    else
        scaleToFit(width, height, view_edge_max);

    // The view only ever shrinks. `zoom` maps coordinates back through this, so
    // an accidental upscale would put the box outside the original.
    assert(size.width <= width);
    assert(size.height <= height);
    assert(size.width > 0);
    assert(size.height > 0);
    return size;
}

/// The size a crop is magnified to: as large as the budget allows, but never
/// more than `zoom_scale_max` times its own size.
pub fn zoomSize(width: u32, height: u32) Size {
    assert(width > 0);
    assert(height > 0);

    const longest = @max(width, height);
    const capped = @min(view_edge_max, longest *| zoom_scale_max);
    const size: Size = if (longest >= capped)
        .{ .width = width, .height = height }
    else
        scaleToFit(width, height, capped);

    // A zoom only ever grows, and never past the budget.
    assert(size.width >= width);
    assert(size.height >= height);
    assert(size.width <= view_edge_max or size.width == width);
    assert(size.height <= view_edge_max or size.height == height);
    return size;
}

/// Fit within `edge` on the longest side, preserving aspect ratio, never
/// rounding a dimension down to zero.
fn scaleToFit(width: u32, height: u32, edge: u32) Size {
    assert(width > 0);
    assert(height > 0);
    assert(edge > 0);

    if (width >= height) {
        const scaled = @as(u64, height) * edge / width;
        return .{ .width = edge, .height = @max(1, @as(u32, @intCast(scaled))) };
    }
    const scaled = @as(u64, width) * edge / height;
    return .{ .width = @max(1, @as(u32, @intCast(scaled))), .height = edge };
}

/// A box as a model reported it: signed, possibly inverted, possibly outside the
/// image. A struct rather than four loose integers so the corners cannot be
/// swapped at a call site. `clampRect` turns one into a `Rect`.
pub const Box = struct {
    x1: i64,
    y1: i64,
    x2: i64,
    y2: i64,
};

/// A rectangle in pixels, `x2`/`y2` exclusive.
pub const Rect = struct {
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,

    pub fn width(self: Rect) u32 {
        return self.x2 - self.x1;
    }

    pub fn height(self: Rect) u32 {
        return self.y2 - self.y1;
    }
};

/// Clamp a model-supplied box to `bounds`, or null when nothing is left of it.
///
/// Coordinates come from a model reading an image, so they are estimates: off
/// the edge, inverted, or zero-area. Clamping and then reporting what was
/// actually used beats rejecting a box that is 3 pixels too wide.
pub fn clampRect(box: Box, bounds: Size) ?Rect {
    assert(bounds.width > 0);
    assert(bounds.height > 0);

    const left = clampAxis(@min(box.x1, box.x2), bounds.width);
    const right = clampAxis(@max(box.x1, box.x2), bounds.width);
    const top = clampAxis(@min(box.y1, box.y2), bounds.height);
    const bottom = clampAxis(@max(box.y1, box.y2), bounds.height);
    if (left >= right) return null;
    if (top >= bottom) return null;

    const rect: Rect = .{ .x1 = left, .y1 = top, .x2 = right, .y2 = bottom };
    assert(rect.x2 <= bounds.width);
    assert(rect.y2 <= bounds.height);
    return rect;
}

fn clampAxis(value: i64, limit: u32) u32 {
    assert(limit > 0);
    if (value < 0) return 0;
    if (value > limit) return limit;
    return @intCast(value);
}

/// Map a rectangle from view coordinates onto the original image. The model named
/// the box in the view it was shown, but the pixels worth zooming into only exist
/// at full resolution.
pub fn scaleRect(rect: Rect, from: Size, to: Size) Rect {
    assert(from.width > 0);
    assert(from.height > 0);
    assert(rect.x2 <= from.width);
    assert(rect.y2 <= from.height);

    const x1 = mapAxis(rect.x1, from.width, to.width);
    const y1 = mapAxis(rect.y1, from.height, to.height);
    // At least one pixel wide, however small the source box was.
    const x2 = @max(x1 + 1, mapAxis(rect.x2, from.width, to.width));
    const y2 = @max(y1 + 1, mapAxis(rect.y2, from.height, to.height));
    const mapped: Rect = .{
        .x1 = x1,
        .y1 = y1,
        .x2 = @min(x2, to.width),
        .y2 = @min(y2, to.height),
    };

    // The caller crops with this, so it has to be non-empty and in bounds.
    assert(mapped.width() > 0);
    assert(mapped.height() > 0);
    assert(mapped.x2 <= to.width);
    assert(mapped.y2 <= to.height);
    return mapped;
}

fn mapAxis(value: u32, from: u32, to: u32) u32 {
    assert(from > 0);
    assert(value <= from);
    const scaled = (@as(u64, value) * to + from / 2) / from;
    return @intCast(@min(scaled, to));
}

/// Copy `rect` out of `source` into a new image. Caller owns the result.
pub fn crop(gpa: std.mem.Allocator, source: png.Image, rect: Rect) !png.Image {
    assert(rect.x2 <= source.width);
    assert(rect.y2 <= source.height);
    assert(rect.width() > 0);
    assert(rect.height() > 0);

    const out_width = rect.width();
    const out_height = rect.height();
    const row_bytes: usize = @as(usize, out_width) * 4;
    const pixels = try gpa.alloc(u8, row_bytes * out_height);
    errdefer gpa.free(pixels);

    var y: u32 = 0;
    while (y < out_height) : (y += 1) {
        const source_row = source.pixels[source.offset(rect.x1, rect.y1 + y)..][0..row_bytes];
        const target_row = pixels[@as(usize, y) * row_bytes ..][0..row_bytes];
        @memcpy(target_row, source_row);
    }
    assert(pixels.len == row_bytes * out_height);
    return .{ .width = out_width, .height = out_height, .pixels = pixels };
}

/// Scale `source` to `target`. Averages when shrinking, interpolates when
/// growing; returns a copy when the size already matches. Caller owns the result.
pub fn resize(gpa: std.mem.Allocator, source: png.Image, target: Size) !png.Image {
    assert(target.width > 0);
    assert(target.height > 0);
    assert(source.pixels.len == @as(usize, source.width) * source.height * 4);

    const scaled = blk: {
        if (target.width == source.width and target.height == source.height) {
            break :blk png.Image{
                .width = source.width,
                .height = source.height,
                .pixels = try gpa.dupe(u8, source.pixels),
            };
        }
        if (target.width <= source.width and target.height <= source.height) {
            break :blk try boxDownscale(gpa, source, target);
        }
        break :blk try bilinearUpscale(gpa, source, target);
    };
    assert(scaled.width == target.width);
    assert(scaled.height == target.height);
    assert(scaled.pixels.len == @as(usize, target.width) * target.height * 4);
    return scaled;
}

fn boxDownscale(gpa: std.mem.Allocator, source: png.Image, target: Size) !png.Image {
    assert(target.width <= source.width);
    assert(target.height <= source.height);
    const pixels = try gpa.alloc(u8, @as(usize, target.width) * target.height * 4);
    errdefer gpa.free(pixels);

    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        // Half-open source span for this destination row. Rounding the start down
        // and the end up guarantees every source pixel is counted exactly once.
        const y0: u32 = @intCast(@as(u64, y) * source.height / target.height);
        const y1: u32 = @max(y0 + 1, @as(u32, @intCast(@as(u64, y + 1) * source.height / target.height)));
        var x: u32 = 0;
        while (x < target.width) : (x += 1) {
            const x0: u32 = @intCast(@as(u64, x) * source.width / target.width);
            const x1: u32 = @max(x0 + 1, @as(u32, @intCast(@as(u64, x + 1) * source.width / target.width)));

            var totals: [4]u64 = @splat(0);
            var count: u64 = 0;
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const at = source.offset(sx, sy);
                    inline for (0..4) |channel| totals[channel] += source.pixels[at + channel];
                    count += 1;
                }
            }
            assert(count > 0);
            const out = pixels[(@as(usize, y) * target.width + x) * 4 ..][0..4];
            inline for (0..4) |channel| {
                out[channel] = @intCast((totals[channel] + count / 2) / count);
            }
        }
    }
    return .{ .width = target.width, .height = target.height, .pixels = pixels };
}

fn bilinearUpscale(gpa: std.mem.Allocator, source: png.Image, target: Size) !png.Image {
    assert(target.width >= source.width);
    assert(target.height >= source.height);
    const pixels = try gpa.alloc(u8, @as(usize, target.width) * target.height * 4);
    errdefer gpa.free(pixels);

    // 16.16 fixed point: enough precision for these sizes and no float rounding
    // to reason about.
    const shift = 16;
    const one: u64 = 1 << shift;
    const step_x: u64 = if (target.width == 1) 0 else (@as(u64, source.width - 1) << shift) / (target.width - 1);
    const step_y: u64 = if (target.height == 1) 0 else (@as(u64, source.height - 1) << shift) / (target.height - 1);

    var y: u32 = 0;
    while (y < target.height) : (y += 1) {
        const fy = step_y * y;
        const sy: u32 = @intCast(fy >> shift);
        const wy = fy & (one - 1);
        const sy_next = @min(sy + 1, source.height - 1);
        var x: u32 = 0;
        while (x < target.width) : (x += 1) {
            const fx = step_x * x;
            const sx: u32 = @intCast(fx >> shift);
            const wx = fx & (one - 1);
            const sx_next = @min(sx + 1, source.width - 1);

            const top_left = source.offset(sx, sy);
            const top_right = source.offset(sx_next, sy);
            const bottom_left = source.offset(sx, sy_next);
            const bottom_right = source.offset(sx_next, sy_next);
            const out = pixels[(@as(usize, y) * target.width + x) * 4 ..][0..4];
            inline for (0..4) |channel| {
                const top = lerp(source.pixels[top_left + channel], source.pixels[top_right + channel], wx, one);
                const bottom = lerp(source.pixels[bottom_left + channel], source.pixels[bottom_right + channel], wx, one);
                out[channel] = @intCast((top * (one - wy) + bottom * wy + one / 2) >> shift);
            }
        }
    }
    return .{ .width = target.width, .height = target.height, .pixels = pixels };
}

fn lerp(a: u8, b: u8, weight: u64, one: u64) u64 {
    assert(weight < one);
    return (@as(u64, a) * (one - weight) + @as(u64, b) * weight) >> 16;
}

fn solid(gpa: std.mem.Allocator, width: u32, height: u32, colour: [4]u8) !png.Image {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) @memcpy(pixels[i..][0..4], &colour);
    return .{ .width = width, .height = height, .pixels = pixels };
}

test "viewSize leaves a small image alone and fits a large one to the cap" {
    try std.testing.expectEqual(Size{ .width = 800, .height = 600 }, viewSize(800, 600));
    try std.testing.expectEqual(Size{ .width = view_edge_max, .height = 100 }, viewSize(view_edge_max, 100));
    const wide = viewSize(4000, 2000);
    try std.testing.expectEqual(view_edge_max, wide.width);
    try std.testing.expectEqual(view_edge_max / 2, wide.height);
    const tall = viewSize(1000, 5000);
    try std.testing.expectEqual(view_edge_max, tall.height);
    // An extreme ratio must not round a dimension to zero.
    const sliver = viewSize(1, 100_000);
    try std.testing.expect(sliver.width >= 1);
}

test "zoomSize magnifies up to the budget but not past the scale ceiling" {
    const modest = zoomSize(400, 200);
    try std.testing.expectEqual(view_edge_max, modest.width);
    // A tiny crop is capped by the scale ceiling, not the budget: 4x16 = 64.
    const tiny = zoomSize(4, 4);
    try std.testing.expectEqual(@as(u32, 64), tiny.width);
    try std.testing.expect(tiny.width < view_edge_max);
    try std.testing.expectEqual(Size{ .width = 2000, .height = 100 }, zoomSize(2000, 100));
}

test "clampRect pulls a model's estimate inside the image" {
    const bounds: Size = .{ .width = 100, .height = 50 };
    const clamped = clampRect(.{ .x1 = -20, .y1 = -5, .x2 = 500, .y2 = 500 }, bounds).?;
    try std.testing.expectEqual(Rect{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 50 }, clamped);
    const flipped = clampRect(.{ .x1 = 80, .y1 = 40, .x2 = 20, .y2 = 10 }, bounds).?;
    try std.testing.expectEqual(Rect{ .x1 = 20, .y1 = 10, .x2 = 80, .y2 = 40 }, flipped);
    try std.testing.expect(clampRect(.{ .x1 = 10, .y1 = 10, .x2 = 10, .y2 = 20 }, bounds) == null);
    try std.testing.expect(clampRect(.{ .x1 = 200, .y1 = 200, .x2 = 300, .y2 = 300 }, bounds) == null);
}

test "scaleRect maps a view box onto the original and never collapses it" {
    const view: Size = .{ .width = 100, .height = 100 };
    const original: Size = .{ .width = 1000, .height = 1000 };
    const mapped = scaleRect(.{ .x1 = 10, .y1 = 20, .x2 = 30, .y2 = 40 }, view, original);
    try std.testing.expectEqual(Rect{ .x1 = 100, .y1 = 200, .x2 = 300, .y2 = 400 }, mapped);

    // Shrinking the other way must still leave a pixel to crop.
    const shrunk = scaleRect(.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 }, .{ .width = 1000, .height = 1000 }, .{ .width = 10, .height = 10 });
    try std.testing.expect(shrunk.width() >= 1);
    try std.testing.expect(shrunk.height() >= 1);
    try std.testing.expect(shrunk.x2 <= 10);
}

test "crop copies exactly the requested region" {
    const gpa = std.testing.allocator;
    // A 4x4 image where each pixel's red channel encodes its position.
    var source = try solid(gpa, 4, 4, .{ 0, 0, 0, 255 });
    defer source.deinit(gpa);
    for (0..4) |y| {
        for (0..4) |x| {
            source.pixels[source.offset(@intCast(x), @intCast(y))] = @intCast(y * 4 + x);
        }
    }

    var region = try crop(gpa, source, .{ .x1 = 1, .y1 = 1, .x2 = 3, .y2 = 3 });
    defer region.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), region.width);
    try std.testing.expectEqual(@as(u32, 2), region.height);
    try std.testing.expectEqual(@as(u8, 5), region.pixels[region.offset(0, 0)]);
    try std.testing.expectEqual(@as(u8, 6), region.pixels[region.offset(1, 0)]);
    try std.testing.expectEqual(@as(u8, 9), region.pixels[region.offset(0, 1)]);
    try std.testing.expectEqual(@as(u8, 10), region.pixels[region.offset(1, 1)]);
}

test "resize preserves a solid colour in both directions" {
    const gpa = std.testing.allocator;
    var source = try solid(gpa, 40, 30, .{ 12, 34, 56, 255 });
    defer source.deinit(gpa);

    var smaller = try resize(gpa, source, .{ .width = 10, .height = 7 });
    defer smaller.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 10), smaller.width);
    for (0..smaller.pixels.len / 4) |i| {
        try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56, 255 }, smaller.pixels[i * 4 ..][0..4]);
    }

    var larger = try resize(gpa, source, .{ .width = 80, .height = 60 });
    defer larger.deinit(gpa);
    for (0..larger.pixels.len / 4) |i| {
        try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56, 255 }, larger.pixels[i * 4 ..][0..4]);
    }

    var same = try resize(gpa, source, .{ .width = 40, .height = 30 });
    defer same.deinit(gpa);
    try std.testing.expectEqualSlices(u8, source.pixels, same.pixels);
    try std.testing.expect(same.pixels.ptr != source.pixels.ptr);
}

test "downscaling averages rather than dropping pixels" {
    const gpa = std.testing.allocator;
    // Two columns, black and white. Point sampling would return one of them;
    // averaging returns the midpoint — which is why a thin line survives.
    var source = try solid(gpa, 2, 1, .{ 0, 0, 0, 255 });
    defer source.deinit(gpa);
    @memcpy(source.pixels[source.offset(1, 0)..][0..4], &[_]u8{ 255, 255, 255, 255 });

    var shrunk = try resize(gpa, source, .{ .width = 1, .height = 1 });
    defer shrunk.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 128), shrunk.pixels[0]);
}

test "upscaling interpolates between neighbours" {
    const gpa = std.testing.allocator;
    var source = try solid(gpa, 2, 1, .{ 0, 0, 0, 255 });
    defer source.deinit(gpa);
    @memcpy(source.pixels[source.offset(1, 0)..][0..4], &[_]u8{ 100, 100, 100, 255 });

    var grown = try resize(gpa, source, .{ .width = 3, .height = 1 });
    defer grown.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), grown.pixels[grown.offset(0, 0)]);
    try std.testing.expectEqual(@as(u8, 100), grown.pixels[grown.offset(2, 0)]);
    const middle = grown.pixels[grown.offset(1, 0)];
    try std.testing.expect(middle > 40 and middle < 60);
}

test "a crop then a resize round-trips through the codec" {
    const gpa = std.testing.allocator;
    var source = try solid(gpa, 64, 64, .{ 200, 100, 50, 255 });
    defer source.deinit(gpa);
    var region = try crop(gpa, source, .{ .x1 = 16, .y1 = 16, .x2 = 32, .y2 = 32 });
    defer region.deinit(gpa);
    var zoomed = try resize(gpa, region, zoomSize(region.width, region.height));
    defer zoomed.deinit(gpa);

    const bytes = try png.encode(gpa, zoomed);
    defer gpa.free(bytes);
    var decoded = try png.decode(gpa, bytes);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(zoomed.width, decoded.width);
    try std.testing.expectEqualSlices(u8, zoomed.pixels, decoded.pixels);
}
