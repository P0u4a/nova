//! Text mechanics behind the `edit` tool: line-ending handling, match location,
//! multi-edit validation, and diff rendering. Pure string work — no file I/O, no
//! allocator-owned tool types — so every rule below is directly testable.
//!
//! The contract these rules implement:
//!
//!   - Every `old_text` must match the original file exactly once. Edits are
//!     matched against the *original*, never against the result of an earlier
//!     edit in the same call, so the model doesn't have to simulate its own
//!     changes.
//!   - Everything is validated before anything is written, so a rejected call
//!     leaves the file byte-identical.
//!   - Bytes outside the replaced spans survive untouched: the file's dominant
//!     line ending is restored on write and a leading BOM is preserved.
//!
//! Matching normalizes to LF first, then falls back to a whitespace/Unicode
//! tolerant comparison, because models reproduce text with smart quotes, dashes,
//! and trailing-space drift far more often than they get the substance wrong.

const std = @import("std");

const assert = std.debug.assert;

pub const LineEnding = enum {
    lf,
    crlf,

    pub fn sequence(self: LineEnding) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

/// One requested replacement, as it arrives from the model.
pub const Edit = struct {
    old_text: []const u8,
    new_text: []const u8,
};

/// Why an edit could not be applied. Each maps to a message that tells the model
/// what to do differently — see `describe`.
pub const EditError = error{
    NoEdits,
    EmptyOldText,
    NotFound,
    NotUnique,
    Overlapping,
    NoChange,
};

/// Where a validated edit landed in the matched content, plus the text to put
/// there. Offsets are into the content the match was found in.
const Match = struct {
    index: usize,
    len: usize,
    edit_index: usize,
    new_text: []const u8,
};

/// A failed edit, with enough detail for the model to correct itself: which
/// entry, and for `NotUnique`, how many times it actually matched.
pub const Failure = struct {
    reason: EditError,
    /// Index into the caller's edit list; meaningless for `NoEdits`/`NoChange`.
    edit_index: usize = 0,
    /// Occurrence count for `NotUnique`; the other edit's index for `Overlapping`.
    detail: usize = 0,
};

pub const ApplyResult = struct {
    /// The LF-normalized original, the baseline every diff is computed against.
    base: []u8,
    /// The LF-normalized result.
    updated: []u8,
    /// True when at least one edit matched only after whitespace/Unicode
    /// normalization. Surfaced to the model so a sloppy `old_text` is visible
    /// rather than silently tolerated.
    used_fuzzy: bool,

    pub fn deinit(self: *ApplyResult, gpa: std.mem.Allocator) void {
        gpa.free(self.base);
        gpa.free(self.updated);
        self.* = undefined;
    }
};

/// The file's dominant line ending. CRLF only when the first line break in the
/// file is CRLF, matching what an editor would infer.
pub fn detectLineEnding(content: []const u8) LineEnding {
    const lf = std.mem.indexOfScalar(u8, content, '\n') orelse return .lf;
    if (lf == 0) return .lf;
    return if (content[lf - 1] == '\r') .crlf else .lf;
}

pub const bom = "\xEF\xBB\xBF";

pub fn stripBom(content: []const u8) []const u8 {
    if (std.mem.startsWith(u8, content, bom)) return content[bom.len..];
    return content;
}

/// Rewrite CRLF and bare CR to LF so matching only deals with one convention.
pub fn normalizeToLf(gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, content.len);
    var index: usize = 0;
    while (index < content.len) : (index += 1) {
        if (content[index] == '\r') {
            if (index + 1 < content.len and content[index + 1] == '\n') continue;
            try out.append(gpa, '\n');
            continue;
        }
        try out.append(gpa, content[index]);
    }
    return out.toOwnedSlice(gpa);
}

/// Restore `ending` throughout LF-normalized text, for writing back out.
pub fn restoreLineEndings(gpa: std.mem.Allocator, content: []const u8, ending: LineEnding) ![]u8 {
    if (ending == .lf) return gpa.dupe(u8, content);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, content.len);
    for (content) |byte| {
        if (byte == '\n') try out.append(gpa, '\r');
        try out.append(gpa, byte);
    }
    return out.toOwnedSlice(gpa);
}

/// Fold the differences models actually introduce when echoing text back:
/// trailing whitespace per line, smart quotes, Unicode dashes, exotic spaces.
/// Length is NOT preserved, so offsets from this space are only meaningful
/// within it — which is why a fuzzy match applies its edits in this space and
/// then copies untouched lines back from the original (see `applyEdits`).
pub fn normalizeFuzzy(gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, content.len);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const folded = try foldLine(gpa, line);
        defer gpa.free(folded);
        try out.appendSlice(gpa, std.mem.trimEnd(u8, folded, " \t"));
    }
    return out.toOwnedSlice(gpa);
}

/// Map the Unicode characters models substitute for ASCII onto their ASCII
/// equivalents. Anything unrecognized is copied through byte-for-byte.
fn foldLine(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var view = std.unicode.Utf8View.init(line) catch {
        // Not valid UTF-8 — nothing to fold, so pass the bytes through.
        return gpa.dupe(u8, line);
    };
    var iter = view.iterator();
    while (iter.nextCodepoint()) |code| {
        const replacement: ?u8 = switch (code) {
            // Single quotes: ‘ ’ ‚ ‛
            0x2018, 0x2019, 0x201A, 0x201B => '\'',
            // Double quotes: “ ” „ ‟
            0x201C, 0x201D, 0x201E, 0x201F => '"',
            // Dashes and minus: ‐ ‑ ‒ – — ― −
            0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 => '-',
            // Spaces: NBSP, en/em quad through hair space, narrow NBSP,
            // medium math space, ideographic space.
            0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000 => ' ',
            else => null,
        };
        if (replacement) |byte| {
            try out.append(gpa, byte);
            continue;
        }
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(code, &buffer) catch {
            try out.append(gpa, '?');
            continue;
        };
        try out.appendSlice(gpa, buffer[0..len]);
    }
    return out.toOwnedSlice(gpa);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    assert(needle.len > 0);
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |at| {
        count += 1;
        cursor = at + needle.len;
    }
    return count;
}

/// Apply `edits` to LF-normalized `content`, returning both the baseline and the
/// result. Every edit is validated first, so a `Failure` means nothing was
/// applied and the caller must leave the file alone.
///
/// Exact matching is tried against the whole edit set first. Only if some edit
/// fails to match exactly does the whole operation retry in fuzzy space, so a
/// file that matches exactly is never subjected to normalization.
pub fn applyEdits(
    gpa: std.mem.Allocator,
    content: []const u8,
    edits: []const Edit,
    failure: *Failure,
) (std.mem.Allocator.Error || EditError)!ApplyResult {
    if (edits.len == 0) {
        failure.* = .{ .reason = error.NoEdits };
        return error.NoEdits;
    }
    for (edits, 0..) |edit, index| {
        if (edit.old_text.len == 0) {
            failure.* = .{ .reason = error.EmptyOldText, .edit_index = index };
            return error.EmptyOldText;
        }
    }

    const exact = try allMatchExactly(gpa, content, edits);
    if (exact) return applyIn(gpa, content, content, edits, false, failure);

    const fuzzy_content = try normalizeFuzzy(gpa, content);
    defer gpa.free(fuzzy_content);
    return applyIn(gpa, content, fuzzy_content, edits, true, failure);
}

/// Whether every edit's `old_text` appears verbatim in `content`. Cheap probe
/// that decides between the exact and fuzzy paths.
fn allMatchExactly(gpa: std.mem.Allocator, content: []const u8, edits: []const Edit) !bool {
    for (edits) |edit| {
        const normalized = try normalizeToLf(gpa, edit.old_text);
        defer gpa.free(normalized);
        if (std.mem.indexOf(u8, content, normalized) == null) return false;
    }
    return true;
}

/// Locate and apply every edit within `search_space`, then compose the result.
///
/// When `fuzzy` is set, `search_space` is the normalization of `original` and
/// offsets are only valid there; the result is composed line-wise so untouched
/// lines keep their original bytes and only the lines an edit actually touched
/// are taken from normalized space. That way fuzzy matching never silently
/// rewrites unrelated whitespace across the file.
fn applyIn(
    gpa: std.mem.Allocator,
    original: []const u8,
    search_space: []const u8,
    edits: []const Edit,
    fuzzy: bool,
    failure: *Failure,
) (std.mem.Allocator.Error || EditError)!ApplyResult {
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(gpa);
    var owned_new: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_new.items) |text| gpa.free(text);
        owned_new.deinit(gpa);
    }

    for (edits, 0..) |edit, index| {
        const needle_lf = try normalizeToLf(gpa, edit.old_text);
        defer gpa.free(needle_lf);
        const needle = if (fuzzy) try normalizeFuzzy(gpa, needle_lf) else try gpa.dupe(u8, needle_lf);
        defer gpa.free(needle);
        if (needle.len == 0) {
            failure.* = .{ .reason = error.EmptyOldText, .edit_index = index };
            return error.EmptyOldText;
        }

        const count = countOccurrences(search_space, needle);
        if (count == 0) {
            failure.* = .{ .reason = error.NotFound, .edit_index = index };
            return error.NotFound;
        }
        if (count > 1) {
            failure.* = .{ .reason = error.NotUnique, .edit_index = index, .detail = count };
            return error.NotUnique;
        }

        const replacement = try normalizeToLf(gpa, edit.new_text);
        try owned_new.append(gpa, replacement);
        try matches.append(gpa, .{
            .index = std.mem.indexOf(u8, search_space, needle).?,
            .len = needle.len,
            .edit_index = index,
            .new_text = replacement,
        });
    }

    std.mem.sort(Match, matches.items, {}, lessByIndex);
    for (matches.items[1..], 1..) |match, i| {
        const previous = matches.items[i - 1];
        if (previous.index + previous.len > match.index) {
            failure.* = .{
                .reason = error.Overlapping,
                .edit_index = previous.edit_index,
                .detail = match.edit_index,
            };
            return error.Overlapping;
        }
    }

    const base = try normalizeToLf(gpa, original);
    errdefer gpa.free(base);
    const updated = if (fuzzy)
        try spliceAcrossSpaces(gpa, base, search_space, matches.items)
    else
        try splice(gpa, search_space, matches.items);
    errdefer gpa.free(updated);

    if (std.mem.eql(u8, base, updated)) {
        // `base` and `updated` are released by the errdefers above — freeing them
        // here as well would double-free on the way out.
        failure.* = .{ .reason = error.NoChange };
        return error.NoChange;
    }
    return .{ .base = base, .updated = updated, .used_fuzzy = fuzzy };
}

fn lessByIndex(_: void, a: Match, b: Match) bool {
    return a.index < b.index;
}

/// Replace each matched span in `content`. Matches must be sorted and disjoint.
fn splice(gpa: std.mem.Allocator, content: []const u8, matches: []const Match) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var cursor: usize = 0;
    for (matches) |match| {
        try out.appendSlice(gpa, content[cursor..match.index]);
        try out.appendSlice(gpa, match.new_text);
        cursor = match.index + match.len;
    }
    try out.appendSlice(gpa, content[cursor..]);
    return out.toOwnedSlice(gpa);
}

/// Compose the result when matches were found in fuzzy space: take the lines a
/// match touches from the fuzzy splice, and every other line from `base`.
///
/// Both spaces have the same line count (normalization is per line and never
/// adds or removes breaks), so lines correspond one-to-one — that correspondence
/// is what lets untouched lines keep their exact original bytes.
fn spliceAcrossSpaces(
    gpa: std.mem.Allocator,
    base: []const u8,
    fuzzy: []const u8,
    matches: []const Match,
) ![]u8 {
    const spliced = try splice(gpa, fuzzy, matches);
    defer gpa.free(spliced);

    // Which fuzzy-space lines a match overlaps; those come from `spliced`.
    var touched: std.ArrayList(bool) = .empty;
    defer touched.deinit(gpa);
    const fuzzy_lines = countLines(fuzzy);
    try touched.appendNTimes(gpa, false, fuzzy_lines);
    for (matches) |match| {
        const first = countLines(fuzzy[0..match.index]) - 1;
        const last = countLines(fuzzy[0 .. match.index + match.len]) - 1;
        var line = first;
        while (line <= last and line < fuzzy_lines) : (line += 1) touched.items[line] = true;
    }

    const base_lines = countLines(base);
    if (base_lines != fuzzy_lines) {
        // Should not happen (normalization is line-preserving), but rather than
        // risk interleaving the wrong lines, take the splice wholesale.
        return gpa.dupe(u8, spliced);
    }

    // Walk base and spliced in lockstep. A touched *run* is emitted from the
    // spliced side as a whole, because a replacement may change how many lines
    // that run occupies.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var base_iter = std.mem.splitScalar(u8, base, '\n');
    var spliced_iter = std.mem.splitScalar(u8, spliced, '\n');
    var line: usize = 0;
    var first_out = true;
    while (line < fuzzy_lines) : (line += 1) {
        const base_line = base_iter.next() orelse break;
        const spliced_line = spliced_iter.next();
        if (!first_out) try out.append(gpa, '\n');
        first_out = false;
        if (touched.items[line]) {
            try out.appendSlice(gpa, spliced_line orelse "");
        } else {
            try out.appendSlice(gpa, base_line);
        }
    }
    // Any lines the replacement added beyond the original count.
    while (spliced_iter.next()) |extra| {
        if (!first_out) try out.append(gpa, '\n');
        first_out = false;
        try out.appendSlice(gpa, extra);
    }
    return out.toOwnedSlice(gpa);
}

fn countLines(content: []const u8) usize {
    var count: usize = 1;
    for (content) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

/// Model-facing explanation of a failure, phrased as the corrective action.
/// Caller owns the string.
pub fn describe(gpa: std.mem.Allocator, path: []const u8, edits_len: usize, failure: Failure) ![]u8 {
    const one = edits_len <= 1;
    return switch (failure.reason) {
        error.NoEdits => std.fmt.allocPrint(gpa, "edit {s}: `edits` must contain at least one replacement.", .{path}),
        error.EmptyOldText => if (one)
            std.fmt.allocPrint(gpa, "edit {s}: old_text must not be empty.", .{path})
        else
            std.fmt.allocPrint(gpa, "edit {s}: edits[{d}].old_text must not be empty.", .{ path, failure.edit_index }),
        error.NotFound => if (one)
            std.fmt.allocPrint(gpa, "edit {s}: old_text was not found. It must match the file exactly, including whitespace and newlines — read the file and copy the text verbatim.", .{path})
        else
            std.fmt.allocPrint(gpa, "edit {s}: edits[{d}].old_text was not found. It must match the file exactly, including whitespace and newlines — read the file and copy the text verbatim.", .{ path, failure.edit_index }),
        error.NotUnique => if (one)
            std.fmt.allocPrint(gpa, "edit {s}: old_text matches {d} places. Add surrounding context so it identifies exactly one.", .{ path, failure.detail })
        else
            std.fmt.allocPrint(gpa, "edit {s}: edits[{d}].old_text matches {d} places. Add surrounding context so it identifies exactly one.", .{ path, failure.edit_index, failure.detail }),
        error.Overlapping => std.fmt.allocPrint(gpa, "edit {s}: edits[{d}] and edits[{d}] overlap. Merge them into one replacement, or target disjoint regions.", .{ path, failure.edit_index, failure.detail }),
        error.NoChange => std.fmt.allocPrint(gpa, "edit {s}: the replacement produced identical content — nothing to do.", .{path}),
    };
}

/// A unified-style diff with line numbers, for the human display channel.
/// Unchanged regions are elided beyond `context` lines on each side.
///
/// The writer underneath only ever fails by failing to allocate, so the whole
/// thing surfaces as `OutOfMemory` and callers don't need a wider error set.
pub fn renderDiff(
    gpa: std.mem.Allocator,
    path: []const u8,
    before: []const u8,
    after: []const u8,
    context: usize,
) std.mem.Allocator.Error![]u8 {
    return renderDiffFallible(gpa, path, before, after, context) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.OutOfMemory,
    };
}

fn renderDiffFallible(
    gpa: std.mem.Allocator,
    path: []const u8,
    before: []const u8,
    after: []const u8,
    context: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);
    defer writer.deinit();

    try writer.writer.print("{s}\n", .{path});

    var before_lines = try splitLines(gpa, before);
    defer before_lines.deinit(gpa);
    var after_lines = try splitLines(gpa, after);
    defer after_lines.deinit(gpa);

    // Common prefix and suffix bound the changed region. Enough for edit output,
    // where changes are localized replacements rather than arbitrary rewrites.
    var prefix: usize = 0;
    while (prefix < before_lines.items.len and
        prefix < after_lines.items.len and
        std.mem.eql(u8, before_lines.items[prefix], after_lines.items[prefix])) : (prefix += 1)
    {}
    var suffix: usize = 0;
    while (suffix < before_lines.items.len - prefix and
        suffix < after_lines.items.len - prefix and
        std.mem.eql(
            u8,
            before_lines.items[before_lines.items.len - 1 - suffix],
            after_lines.items[after_lines.items.len - 1 - suffix],
        )) : (suffix += 1)
    {}

    const width = numberWidth(@max(before_lines.items.len, after_lines.items.len));
    const lead = prefix -| context;
    if (lead > 0) try writer.writer.print(" {s} ...\n", .{" " ** 0});

    var line = lead;
    while (line < prefix) : (line += 1) {
        try writeNumbered(&writer.writer, ' ', line + 1, width, before_lines.items[line]);
    }
    var removed = prefix;
    while (removed < before_lines.items.len - suffix) : (removed += 1) {
        try writeNumbered(&writer.writer, '-', removed + 1, width, before_lines.items[removed]);
    }
    var added = prefix;
    while (added < after_lines.items.len - suffix) : (added += 1) {
        try writeNumbered(&writer.writer, '+', added + 1, width, after_lines.items[added]);
    }
    const trail_end = @min(before_lines.items.len, before_lines.items.len - suffix + context);
    var trail = before_lines.items.len - suffix;
    while (trail < trail_end) : (trail += 1) {
        try writeNumbered(&writer.writer, ' ', trail + 1, width, before_lines.items[trail]);
    }
    if (trail_end < before_lines.items.len) try writer.writer.writeAll("    ...\n");

    return writer.toOwnedSlice();
}

fn writeNumbered(writer: *std.Io.Writer, marker: u8, number: usize, width: usize, text: []const u8) !void {
    try writer.writeByte(marker);
    var digits: [24]u8 = undefined;
    const rendered = std.fmt.bufPrint(&digits, "{d}", .{number}) catch "?";
    var pad = width -| rendered.len;
    while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
    try writer.writeAll(rendered);
    try writer.writeByte(' ');
    try writer.writeAll(text);
    try writer.writeByte('\n');
}

fn numberWidth(count: usize) usize {
    var width: usize = 1;
    var value = count;
    while (value >= 10) : (value /= 10) width += 1;
    return width;
}

/// Split into lines, dropping the trailing empty element a final newline creates
/// so a file ending in a newline doesn't render a phantom last line.
fn splitLines(gpa: std.mem.Allocator, content: []const u8) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| try lines.append(gpa, line);
    if (lines.items.len > 1 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines;
}

/// Lines added and removed, for the one-line result the model sees.
pub const Counts = struct { added: usize, removed: usize };

pub fn countChanges(before: []const u8, after: []const u8) Counts {
    var counts: Counts = .{ .added = 0, .removed = 0 };
    var before_iter = std.mem.splitScalar(u8, before, '\n');
    var after_iter = std.mem.splitScalar(u8, after, '\n');
    // Skip the common prefix and count the rest; adequate for a summary line.
    while (true) {
        const b = before_iter.peek();
        const a = after_iter.peek();
        if (b == null or a == null) break;
        if (!std.mem.eql(u8, b.?, a.?)) break;
        _ = before_iter.next();
        _ = after_iter.next();
    }
    while (before_iter.next()) |_| counts.removed += 1;
    while (after_iter.next()) |_| counts.added += 1;
    return counts;
}

// === tests ==================================================================

test "detectLineEnding follows the first break" {
    try std.testing.expectEqual(LineEnding.lf, detectLineEnding("a\nb\r\n"));
    try std.testing.expectEqual(LineEnding.crlf, detectLineEnding("a\r\nb\n"));
    try std.testing.expectEqual(LineEnding.lf, detectLineEnding("no breaks"));
    try std.testing.expectEqual(LineEnding.lf, detectLineEnding("\nleading"));
}

test "normalizeToLf collapses CRLF and bare CR" {
    const gpa = std.testing.allocator;
    const out = try normalizeToLf(gpa, "a\r\nb\rc\nd");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\nb\nc\nd", out);
}

test "restoreLineEndings round-trips CRLF" {
    const gpa = std.testing.allocator;
    const normalized = try normalizeToLf(gpa, "a\r\nb\r\n");
    defer gpa.free(normalized);
    const restored = try restoreLineEndings(gpa, normalized, .crlf);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings("a\r\nb\r\n", restored);
}

test "single exact edit replaces the span and leaves the rest alone" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    var result = try applyEdits(gpa, "one\ntwo\nthree\n", &.{
        .{ .old_text = "two", .new_text = "TWO" },
    }, &failure);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("one\nTWO\nthree\n", result.updated);
    try std.testing.expect(!result.used_fuzzy);
}

test "several edits all match the original, not each other's output" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    // If edits were applied incrementally, the second would match the first's
    // output and produce "bb" instead of "b".
    var result = try applyEdits(gpa, "a\nb\n", &.{
        .{ .old_text = "a", .new_text = "b" },
        .{ .old_text = "b", .new_text = "c" },
    }, &failure);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("b\nc\n", result.updated);
}

test "a non-unique old_text is refused with its occurrence count" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    try std.testing.expectError(error.NotUnique, applyEdits(gpa, "x\nx\nx\n", &.{
        .{ .old_text = "x", .new_text = "y" },
    }, &failure));
    try std.testing.expectEqual(@as(usize, 3), failure.detail);

    const message = try describe(gpa, "f.zig", 1, failure);
    defer gpa.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "matches 3 places") != null);
}

test "a missing old_text is refused" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    try std.testing.expectError(error.NotFound, applyEdits(gpa, "hello\n", &.{
        .{ .old_text = "goodbye", .new_text = "hi" },
    }, &failure));
    try std.testing.expectEqual(@as(usize, 0), failure.edit_index);
}

test "overlapping edits are refused and name both entries" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    try std.testing.expectError(error.Overlapping, applyEdits(gpa, "abcdef\n", &.{
        .{ .old_text = "abcd", .new_text = "X" },
        .{ .old_text = "cdef", .new_text = "Y" },
    }, &failure));
    const message = try describe(gpa, "f.zig", 2, failure);
    defer gpa.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "overlap") != null);
}

test "an edit that changes nothing is refused" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    try std.testing.expectError(error.NoChange, applyEdits(gpa, "same\n", &.{
        .{ .old_text = "same", .new_text = "same" },
    }, &failure));
}

test "an empty old_text is refused before any matching" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    try std.testing.expectError(error.EmptyOldText, applyEdits(gpa, "x\n", &.{
        .{ .old_text = "", .new_text = "y" },
    }, &failure));
}

test "fuzzy match tolerates smart quotes and trailing whitespace" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    // The file has an ASCII apostrophe and a trailing space; the model supplies
    // a smart apostrophe and no trailing space.
    var result = try applyEdits(gpa, "const s = 'it\\'s';   \nnext\n", &.{
        .{ .old_text = "const s = \u{2018}it\\\u{2019}s\u{2019};", .new_text = "const s = \"its\";" },
    }, &failure);
    defer result.deinit(gpa);
    try std.testing.expect(result.used_fuzzy);
    try std.testing.expect(std.mem.indexOf(u8, result.updated, "const s = \"its\";") != null);
    // The untouched line keeps its original bytes.
    try std.testing.expect(std.mem.indexOf(u8, result.updated, "next") != null);
}

test "fuzzy edit preserves trailing whitespace on lines it did not touch" {
    const gpa = std.testing.allocator;
    var failure: Failure = undefined;
    const original = "alpha\u{2019}s\nkeep   \n";
    var result = try applyEdits(gpa, original, &.{
        .{ .old_text = "alpha's", .new_text = "beta" },
    }, &failure);
    defer result.deinit(gpa);
    try std.testing.expect(result.used_fuzzy);
    try std.testing.expectEqualStrings("beta\nkeep   \n", result.updated);
}

test "renderDiff marks removed and added lines with numbers" {
    const gpa = std.testing.allocator;
    const diff = try renderDiff(gpa, "src/x.zig", "a\nb\nc\n", "a\nB\nc\n", 4);
    defer gpa.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "src/x.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-2 b") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+2 B") != null);
}

test "countChanges reports added and removed line counts" {
    const counts = countChanges("a\nb\nc\n", "a\nB\nC\nD\n");
    try std.testing.expect(counts.removed > 0);
    try std.testing.expect(counts.added >= counts.removed);
}
