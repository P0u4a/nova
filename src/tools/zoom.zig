//! The `zoom` tool: crop a region out of an image and magnify it.
//!
//! A model sees an image as a grid of patches. Anything finer than a patch — a
//! tick label, two lines eight pixels apart — is physically not there to read, no
//! matter how carefully it looks. Cropping that region out of the full-resolution
//! file and scaling it up puts the detail back within reach, and the model can
//! zoom again on the result.
//!
//! The design is adapted from Anthropic's multimodal crop-tool cookbook, with one
//! deliberate difference: the region is addressed by **path**, not by an index
//! into the images already in the conversation. Nova keeps no image registry, and
//! a path is both stateless and more useful — the agent can zoom into a file it
//! has never viewed.
//!
//! Coordinates are in the space `view_image` reports, which is why `image.view`
//! decides the view size rather than letting the provider downscale invisibly:
//! `zoom` recomputes the identical view from the file and maps the box back onto
//! the original. Both sides agree on what "pixel (400, 300)" means without any
//! state travelling between calls.

const std = @import("std");

const common = @import("common.zig");
const image = @import("../image.zig");
const workspace_path = @import("workspace_path.zig");

const assert = std.debug.assert;

/// Cap on the file this tool will decode. Higher than `image.bytes_max`, which
/// bounds what gets *attached*: a 12 MB source PNG is fine to crop from, because
/// only the magnified crop is sent.
const source_bytes_max: usize = 32 * 1024 * 1024;

pub const tool: common.Tool = .{
    .name = "zoom",
    .description = @embedFile("../prompts/tools/zoom.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "path",
                .kind = .string,
                .description = "Image file to zoom into. Relative to the project unless absolute; must stay inside the project. PNG only.",
                .required = true,
            },
            .{
                .name = "x1",
                .kind = .integer,
                .description = "Left edge of the region, in pixels of the image as you see it (origin is the top-left corner).",
                .required = true,
            },
            .{
                .name = "y1",
                .kind = .integer,
                .description = "Top edge of the region, in pixels.",
                .required = true,
            },
            .{
                .name = "x2",
                .kind = .integer,
                .description = "Right edge of the region, in pixels. Must be greater than x1.",
                .required = true,
            },
            .{
                .name = "y2",
                .kind = .integer,
                .description = "Bottom edge of the region, in pixels. Must be greater than y1.",
                .required = true,
            },
        },
    },
    .run = run,
};

const JsonArgs = struct {
    path: ?[]const u8 = null,
    x1: ?i64 = null,
    y1: ?i64 = null,
    x2: ?i64 = null,
    y2: ?i64 = null,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch {
        return common.failFmt(gpa, 2, "zoom: could not parse arguments as JSON.\n", .{});
    };
    defer parsed.deinit();
    const args = parsed.value;

    const path = args.path orelse return missingPath(gpa);
    if (path.len == 0) return missingPath(gpa);
    const box: image.raster.Box = .{
        .x1 = args.x1 orelse return missingCoordinates(gpa, path),
        .y1 = args.y1 orelse return missingCoordinates(gpa, path),
        .x2 = args.x2 orelse return missingCoordinates(gpa, path),
        .y2 = args.y2 orelse return missingCoordinates(gpa, path),
    };

    var resolved = workspace_path.resolve(gpa, io, cwd, path, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        var buffer: [512]u8 = undefined;
        return common.failFmt(gpa, 2, "{s}\n", .{workspace_path.describe(err, "zoom", path, &buffer)});
    };
    defer resolved.deinit(gpa, io);

    const bytes = readAll(gpa, io, &resolved, source_bytes_max) catch |err| {
        return common.failFmt(gpa, 2, "zoom {s}: {s}\n", .{ path, readErrorText(err) });
    };
    defer gpa.free(bytes);

    // The same `view` the model was shown, recomputed rather than remembered.
    var shown = (try image.view(gpa, bytes)) orelse {
        return common.failFmt(gpa, 2, "zoom {s}: not an image Nova can read.\n", .{path});
    };
    defer shown.deinit(gpa);
    if (!shown.zoomable()) return notDecodable(gpa, path, shown.kind);
    const view_size: image.raster.Size = .{ .width = shown.width, .height = shown.height };

    // Clamp rather than reject: the coordinates are a model's read of an image,
    // so a box a few pixels over the edge is an estimate, not a mistake.
    const requested = image.raster.clampRect(box, view_size) orelse return emptyBox(gpa, path, box, view_size);

    var result = magnify(gpa, bytes, requested, view_size) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return common.failFmt(gpa, 2, "zoom {s}: {s}\n", .{ path, decodeErrorText(err) });
    };
    defer result.deinit(gpa);
    if (result.bytes.len > image.bytes_max) return tooLarge(gpa, path, result.bytes.len);

    return attach(gpa, path, requested, view_size, result);
}

fn missingPath(gpa: std.mem.Allocator) common.Error!common.Output {
    return common.failFmt(gpa, 2, "zoom: `path` is required.\n", .{});
}

fn missingCoordinates(gpa: std.mem.Allocator, path: []const u8) common.Error!common.Output {
    return common.failFmt(gpa, 2, "zoom {s}: all four of `x1`, `y1`, `x2`, `y2` are required.\n", .{path});
}

fn notDecodable(gpa: std.mem.Allocator, path: []const u8, kind: image.Kind) common.Error!common.Output {
    return common.failFmt(
        gpa,
        2,
        "zoom {s}: Nova only decodes PNG pixels, and this is {s}. Convert it with bash (e.g. `magick in out.png`) and zoom the PNG.\n",
        .{ path, kind.mimeType() },
    );
}

fn emptyBox(
    gpa: std.mem.Allocator,
    path: []const u8,
    box: image.raster.Box,
    view_size: image.raster.Size,
) common.Error!common.Output {
    return common.failFmt(
        gpa,
        2,
        "zoom {s}: ({d},{d})-({d},{d}) is empty or entirely outside the {d}x{d} image. Give a box with x2 > x1 and y2 > y1, inside those bounds.\n",
        .{ path, box.x1, box.y1, box.x2, box.y2, view_size.width, view_size.height },
    );
}

fn tooLarge(gpa: std.mem.Allocator, path: []const u8, bytes_len: usize) common.Error!common.Output {
    return common.failFmt(
        gpa,
        2,
        "zoom {s}: the magnified region came to {d} bytes, over the {d}-byte attachment limit. Zoom into a smaller box.\n",
        .{ path, bytes_len, image.bytes_max },
    );
}

/// Assemble the successful result: the observation plus the magnified image.
fn attach(
    gpa: std.mem.Allocator,
    path: []const u8,
    requested: image.raster.Rect,
    view_size: image.raster.Size,
    result: Magnified,
) common.Error!common.Output {
    assert(result.bytes.len > 0);
    assert(result.bytes.len <= image.bytes_max);

    const observation = try describe(gpa, path, requested, view_size, result);
    errdefer gpa.free(observation);
    const data = try image.encodeBase64(gpa, result.bytes);
    errdefer gpa.free(data);
    const mime = try gpa.dupe(u8, image.Kind.png.mimeType());
    errdefer gpa.free(mime);

    const stderr = try gpa.alloc(u8, 0);
    return .{
        .stdout = observation,
        .stderr = stderr,
        .code = 0,
        .image = .{ .mime_type = mime, .data_base64 = data },
    };
}

/// A magnified crop, ready to attach.
const Magnified = struct {
    /// The region's size in the original image, before magnification.
    region: image.raster.Size,
    /// The size it was magnified to, which is the size of `bytes`.
    magnified: image.raster.Size,
    /// The encoded PNG. Owned.
    bytes: []u8,

    fn deinit(self: *Magnified, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Decode, crop and magnify, with no decisions of its own — `run` owns the
/// branching, this owns the pixels.
///
/// The box is mapped onto the original and cropped from there: cropping the view
/// would magnify pixels that had already been averaged away, which is the whole
/// thing this tool exists to avoid.
fn magnify(
    gpa: std.mem.Allocator,
    source_png: []const u8,
    requested: image.raster.Rect,
    view_size: image.raster.Size,
) image.png.Error!Magnified {
    assert(requested.width() > 0);
    assert(requested.height() > 0);
    assert(requested.x2 <= view_size.width);
    assert(requested.y2 <= view_size.height);

    var original = try image.png.decode(gpa, source_png);
    defer original.deinit(gpa);

    const original_size: image.raster.Size = .{ .width = original.width, .height = original.height };
    const region = image.raster.scaleRect(requested, view_size, original_size);
    var cropped = image.raster.crop(gpa, original, region) catch return error.OutOfMemory;
    defer cropped.deinit(gpa);

    const target = image.raster.zoomSize(cropped.width, cropped.height);
    var magnified = image.raster.resize(gpa, cropped, target) catch return error.OutOfMemory;
    defer magnified.deinit(gpa);

    // Encoding our own freshly built image can only run out of memory.
    const bytes = image.png.encode(gpa, magnified) catch return error.OutOfMemory;
    assert(magnified.width >= cropped.width);
    assert(magnified.height >= cropped.height);
    return .{
        .region = .{ .width = cropped.width, .height = cropped.height },
        .magnified = .{ .width = magnified.width, .height = magnified.height },
        .bytes = bytes,
    };
}

/// The observation text: which box was used, how much of the original it covered,
/// and what it was magnified to.
///
/// Reporting the box back matters because it may have been clamped — the model
/// needs to know whether it got what it asked for. And the sizes tell it whether
/// zooming again will help or whether it is already looking at raw pixels.
fn describe(
    gpa: std.mem.Allocator,
    path: []const u8,
    requested: image.raster.Rect,
    view_size: image.raster.Size,
    result: Magnified,
) common.Error![]u8 {
    assert(path.len > 0);
    assert(result.region.width > 0);
    assert(result.magnified.width >= result.region.width);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.print(
        "Zoomed {s} into ({d},{d})-({d},{d}) of the {d}x{d} image you were shown: a {d}x{d} region of the original, attached magnified to {d}x{d}.",
        .{
            path,
            requested.x1,
            requested.y1,
            requested.x2,
            requested.y2,
            view_size.width,
            view_size.height,
            result.region.width,
            result.region.height,
            result.magnified.width,
            result.magnified.height,
        },
    ) catch return error.OutOfMemory;
    if (result.magnified.width == result.region.width) {
        w.writeAll(
            " That is already the original's own pixels — zooming further will not add detail.",
        ) catch return error.OutOfMemory;
    } else {
        w.writeAll(
            " Coordinates in a further `zoom` are still in the original image's view space, not this crop's.",
        ) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn readAll(
    gpa: std.mem.Allocator,
    io: std.Io,
    resolved: *const workspace_path.Resolved,
    limit: usize,
) ![]u8 {
    assert(limit > 0);
    var file = try resolved.openFile(io);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(limit));
}

fn readErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file.",
        error.IsDir => "that path is a directory, not a file.",
        error.AccessDenied => "permission denied.",
        error.StreamTooLong => "file is too large to decode.",
        else => "could not read the file.",
    };
}

fn decodeErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.Unsupported => "this PNG uses a feature Nova's decoder does not implement (interlacing, most likely). Re-save it without interlacing using bash.",
        error.TooLarge => "this PNG's pixel dimensions are too large to decode.",
        else => "this PNG could not be decoded; it may be corrupt.",
    };
}

const test_dir = ".zig-cache/zoom-tool-test";

/// Write a PNG whose pixels encode their own position, so a crop can be checked
/// against exact expected values.
fn writeGradient(gpa: std.mem.Allocator, io: std.Io, name: []const u8, width: u32, height: u32) !void {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(pixels);
    for (0..height) |y| {
        for (0..width) |x| {
            const at = (y * width + x) * 4;
            pixels[at + 0] = @truncate(x);
            pixels[at + 1] = @truncate(y);
            pixels[at + 2] = 0;
            pixels[at + 3] = 255;
        }
    }
    const source: image.png.Image = .{ .width = width, .height = height, .pixels = pixels };
    const bytes = try image.png.encode(gpa, source);
    defer gpa.free(bytes);

    try std.Io.Dir.createDirPath(.cwd(), io, test_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, test_dir, .{});
    defer dir.close(io);
    var file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn runInTemp(gpa: std.mem.Allocator, io: std.Io, arguments: []const u8) !common.Output {
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, test_dir);
    const cwd = try std.fs.path.join(gpa, &.{ root, test_dir });
    defer gpa.free(cwd);
    return run(gpa, io, cwd, arguments);
}

fn attachedImage(gpa: std.mem.Allocator, output: common.Output) !image.png.Image {
    const attached = output.image orelse return error.TestFailed;
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(attached.data_base64);
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);
    try decoder.decode(bytes, attached.data_base64);
    return image.png.decode(gpa, bytes);
}

test "zoom crops the named region and magnifies it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeGradient(gpa, io, "grad.png", 100, 100);

    var output = try runInTemp(gpa, io,
        \\{"path":"grad.png","x1":10,"y1":20,"x2":30,"y2":40}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);

    var attached = try attachedImage(gpa, output);
    defer attached.deinit(gpa);
    // 20x20 crop, magnified by the scale ceiling (16x) rather than to the full
    // view budget.
    try std.testing.expectEqual(@as(u32, 320), attached.width);
    try std.testing.expectEqual(@as(u32, 320), attached.height);

    try std.testing.expectEqual(@as(u8, 10), attached.pixels[attached.offset(0, 0)]);
    try std.testing.expectEqual(@as(u8, 20), attached.pixels[attached.offset(0, 0) + 1]);

    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "(10,20)-(30,40)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "100x100") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "20x20") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "320x320") != null);
}

test "zoom crops from the original, not from the downscaled view" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Wider than the view cap, so the model sees a shrunk copy.
    const width = image.raster.view_edge_max * 2;
    try writeGradient(gpa, io, "big.png", width, 200);

    // A 10x10 box in view space covers 20x20 of the original.
    var output = try runInTemp(gpa, io,
        \\{"path":"big.png","x1":0,"y1":0,"x2":10,"y2":10}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "20x20 region of the original") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "1568x") != null);
}

test "zoom clamps a box that runs off the edge and says what it used" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeGradient(gpa, io, "small.png", 40, 40);

    var output = try runInTemp(gpa, io,
        \\{"path":"small.png","x1":-50,"y1":20,"x2":500,"y2":900}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "(0,20)-(40,40)") != null);
}

test "zoom normalises an inverted box rather than refusing it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeGradient(gpa, io, "flip.png", 40, 40);

    var output = try runInTemp(gpa, io,
        \\{"path":"flip.png","x1":30,"y1":30,"x2":10,"y2":10}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "(10,10)-(30,30)") != null);
}

test "zoom refuses an empty box and a box entirely outside the image" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeGradient(gpa, io, "empty.png", 40, 40);

    for ([_][]const u8{
        \\{"path":"empty.png","x1":10,"y1":10,"x2":10,"y2":20}
        ,
        \\{"path":"empty.png","x1":100,"y1":100,"x2":200,"y2":200}
    }) |arguments| {
        var output = try runInTemp(gpa, io, arguments);
        defer output.deinit(gpa);
        try std.testing.expect(output.code != 0);
        try std.testing.expect(output.image == null);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, "empty or entirely outside") != null);
    }
}

test "zoom at full resolution says further zooming will not help" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeGradient(gpa, io, "tiny.png", 4000, 100);

    // A box wide enough that the crop already exceeds the view budget, so there
    // is nothing left to magnify.
    var output = try runInTemp(gpa, io,
        \\{"path":"tiny.png","x1":0,"y1":0,"x2":1568,"y2":100}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "already the original's own pixels") != null);
}

test "zoom refuses a format whose pixels Nova cannot decode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try std.Io.Dir.createDirPath(.cwd(), io, test_dir);
    {
        var dir = try std.Io.Dir.cwd().openDir(io, test_dir, .{});
        defer dir.close(io);
        var file = try dir.createFile(io, "photo.gif", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "GIF89a" ++ ("\x00" ** 16));
    }
    var output = try runInTemp(gpa, io,
        \\{"path":"photo.gif","x1":0,"y1":0,"x2":10,"y2":10}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "only decodes PNG") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "image/gif") != null);
}

test "zoom refuses a path that escapes the project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io,
        \\{"path":"../escaped.png","x1":0,"y1":0,"x2":10,"y2":10}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "outside the workspace") != null);
}

test "zoom requires a path and all four coordinates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    {
        var output = try runInTemp(gpa, io, "{}");
        defer output.deinit(gpa);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, "`path` is required") != null);
    }
    {
        var output = try runInTemp(gpa, io,
            \\{"path":"grad.png","x1":0,"y1":0}
        );
        defer output.deinit(gpa);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, "all four of") != null);
    }
}
