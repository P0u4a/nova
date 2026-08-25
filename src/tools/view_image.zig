//! The `view_image` tool: hand the model an image to actually look at.
//!
//! Nova has no `read` tool — the agent reads files with `cat` through `bash`,
//! which for an image yields binary garbage. So this is the one narrow hatch for
//! pixels, deliberately not a general reader: it takes a path, checks the bytes
//! really are an image, and attaches them.
//!
//! The text output carries the facts on its own — type, path, and the dimensions
//! `zoom` needs — because a tool result cannot carry an image in either OpenAI
//! dialect. The adapters restate the image as a following user message, so this
//! text is what actually persists in history as the tool's result.

const std = @import("std");

const ai = @import("../ai.zig");
const common = @import("common.zig");
const image = @import("../image.zig");
const workspace_path = @import("workspace_path.zig");

const assert = std.debug.assert;

pub const tool: common.Tool = .{
    .name = "view_image",
    .description = @embedFile("../prompts/tools/view_image.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "path",
                .kind = .string,
                .description = "Image file to look at. Relative to the project unless absolute; must stay inside the project.",
                .required = true,
            },
        },
    },
    .run = run,
};

const JsonArgs = struct {
    path: ?[]const u8 = null,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch {
        return common.failFmt(gpa, 2, "view_image: could not parse arguments as JSON.\n", .{});
    };
    defer parsed.deinit();

    const path = parsed.value.path orelse {
        return common.failFmt(gpa, 2, "view_image: `path` is required.\n", .{});
    };
    if (path.len == 0) return common.failFmt(gpa, 2, "view_image: `path` is required.\n", .{});

    var resolved = workspace_path.resolve(gpa, io, cwd, path, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        var buffer: [512]u8 = undefined;
        return common.failFmt(gpa, 2, "{s}\n", .{workspace_path.describe(err, "view_image", path, &buffer)});
    };
    defer resolved.deinit(gpa, io);

    // Read the whole file. `bytes_max + 1` so an oversized file is detected
    // rather than silently truncated into a corrupt image; a PNG over the limit
    // may still fit once the view resize below has run.
    const bytes = readAll(gpa, io, &resolved, image.bytes_max + 1) catch |err| {
        return common.failFmt(gpa, 2, "view_image {s}: {s}\n", .{ path, readErrorText(err) });
    };
    defer gpa.free(bytes);

    var attached = (try image.view(gpa, bytes)) orelse {
        return common.failFmt(
            gpa,
            2,
            "view_image {s}: not an image Nova can read (PNG, JPEG, GIF, WebP or BMP, identified by content rather than extension).\n",
            .{path},
        );
    };
    defer attached.deinit(gpa);

    if (attached.bytes.len > image.bytes_max) {
        return common.failFmt(
            gpa,
            2,
            "view_image {s}: image is {d} bytes, over the {d}-byte limit even after scaling. Attached images stay in the conversation and are re-sent with every later request, so shrink it with bash first and view the smaller copy.\n",
            .{ path, attached.bytes.len, image.bytes_max },
        );
    }

    const observation = try describeView(gpa, path, attached);
    errdefer gpa.free(observation);
    const encoded = try image.encodeBase64(gpa, attached.bytes);
    errdefer gpa.free(encoded);
    const mime = try gpa.dupe(u8, attached.kind.mimeType());
    errdefer gpa.free(mime);

    const stderr = try gpa.alloc(u8, 0);
    return .{
        .stdout = observation,
        .stderr = stderr,
        .code = 0,
        .image = .{ .mime_type = mime, .data_base64 = encoded },
    };
}

/// It carries the dimensions and the coordinate convention because that is the
/// contract `zoom` relies on: the model names a box in the image it was shown,
/// and it can only do that if it knows how big that image is.
fn describeView(gpa: std.mem.Allocator, path: []const u8, attached: image.View) common.Error![]u8 {
    assert(path.len > 0);
    if (attached.zoomable()) assert(attached.width > 0);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.print("Attached {s} for viewing: {s}", .{ attached.kind.mimeType(), path }) catch return error.OutOfMemory;
    if (!attached.zoomable()) {
        // No dimensions to promise, so do not imply any — and say why zooming is
        // out, distinguishing a format we never decode from one file we could not.
        const reason = if (attached.kind == .png)
            "its header could not be read, so `zoom` is unavailable for it"
        else
            "Nova only decodes PNG pixels, so `zoom` is unavailable for this format — convert it with bash if you need to magnify a region";
        w.print(" ({d} bytes). {s}.", .{ attached.bytes.len, reason }) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }
    w.print(" — you are seeing it at {d}x{d} pixels", .{ attached.width, attached.height }) catch return error.OutOfMemory;
    if (attached.resized()) {
        w.print(
            ", scaled down from {d}x{d}",
            .{ attached.source_width, attached.source_height },
        ) catch return error.OutOfMemory;
    }
    w.writeAll(
        ". Pixel coordinates start at (0, 0) in the top-left corner, x increasing right and y increasing down. " ++
            "Use `zoom` with coordinates in that space to magnify anything too small to read confidently.",
    ) catch return error.OutOfMemory;
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
        error.StreamTooLong => "file is far too large to attach; downscale it with bash first.",
        else => "could not read the file.",
    };
}

const test_dir = ".zig-cache/view-image-test";

fn runInTemp(gpa: std.mem.Allocator, io: std.Io, arguments: []const u8) !common.Output {
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, test_dir);
    const cwd = try std.fs.path.join(gpa, &.{ root, test_dir });
    defer gpa.free(cwd);
    return run(gpa, io, cwd, arguments);
}

fn writeTemp(io: std.Io, name: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.createDirPath(.cwd(), io, test_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, test_dir, .{});
    defer dir.close(io);
    var file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// Write a real PNG whose pixels encode their own position.
fn writePng(gpa: std.mem.Allocator, io: std.Io, name: []const u8, width: u32, height: u32) !void {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(pixels);
    for (0..height) |y| {
        for (0..width) |x| {
            const at = (y * width + x) * 4;
            pixels[at + 0] = @truncate(x);
            pixels[at + 1] = @truncate(y);
            pixels[at + 2] = 128;
            pixels[at + 3] = 255;
        }
    }
    const source: image.png.Image = .{ .width = width, .height = height, .pixels = pixels };
    const bytes = try image.png.encode(gpa, source);
    defer gpa.free(bytes);
    try writeTemp(io, name, bytes);
}

test "view_image attaches a real image and reports the size the model sees" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writePng(gpa, io, "shot.png", 120, 80);

    var output = try runInTemp(gpa, io,
        \\{"path":"shot.png"}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    const attached = output.image orelse return error.TestFailed;
    try std.testing.expectEqualStrings("image/png", attached.mime_type);
    try std.testing.expect(std.mem.startsWith(u8, attached.data_base64, "iVBORw0KGgo"));

    // The text stands alone, and carries what `zoom` depends on: the dimensions
    // and the coordinate convention.
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "shot.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "120x80 pixels") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "top-left") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "zoom") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "scaled down") == null);
}

test "view_image shrinks an oversized image and says what it scaled from" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const width = image.raster.view_edge_max + 400;
    try writePng(gpa, io, "big.png", width, 300);

    var output = try runInTemp(gpa, io,
        \\{"path":"big.png"}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    // The model is told the view size, not the file size — that is the space its
    // `zoom` coordinates live in.
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "1568x") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "scaled down from 1968x300") != null);

    // And the attachment really is the smaller image.
    const attached = output.image orelse return error.TestFailed;
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(attached.data_base64);
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);
    try decoder.decode(bytes, attached.data_base64);
    const sent = try image.png.dimensions(bytes);
    try std.testing.expectEqual(image.raster.view_edge_max, sent.width);
}

test "view_image passes a format it cannot decode through and says zoom is out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeTemp(io, "anim.gif", "GIF89a" ++ ("\x00" ** 16));

    var output = try runInTemp(gpa, io,
        \\{"path":"anim.gif"}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(output.image != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "only decodes PNG") != null);
    // No dimensions are promised for something we did not decode.
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "you are seeing it at") == null);
}

test "view_image trusts content over extension" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // A GIF named .png is attached as a GIF, not mislabelled.
    try writeTemp(io, "mislabelled.png", "GIF89a" ++ ("\x00" ** 16));
    var output = try runInTemp(gpa, io,
        \\{"path":"mislabelled.png"}
    );
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("image/gif", (output.image orelse return error.TestFailed).mime_type);
}

test "view_image refuses a file that is not an image" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try writeTemp(io, "notes.txt", "just some text\n");
    var output = try runInTemp(gpa, io,
        \\{"path":"notes.txt"}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(output.image == null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "not an image") != null);
}

test "view_image refuses a path that escapes the project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io,
        \\{"path":"../escaped.png"}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(output.image == null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "outside the workspace") != null);
}

test "view_image reports a missing file rather than attaching nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io,
        \\{"path":"absent.png"}
    );
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "no such file") != null);
}

test "view_image requires a path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try runInTemp(gpa, io, "{}");
    defer output.deinit(gpa);
    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "`path` is required") != null);
}
