const std = @import("std");

const bigrams = @import("bigrams.zig");

const assert = std.debug.assert;

/// Stable separator between an anchor (`LINE+HASH`) and the line body in
/// hashline-prefixed read output.
pub const body_sep = '|';

/// Compute the two-character bigram hash for a line. Trailing whitespace and
/// trailing CRs are stripped before hashing so CRLF/LF differences and stray
/// trailing spaces don't shift hashes. Lines with no alphanumeric content
/// (e.g. brace-only lines) mix the line index into the seed so adjacent
/// identical punctuation lines still get distinct anchors.
pub fn computeLineHash(line_idx: u32, raw_line: []const u8) []const u8 {
    assert(line_idx >= 1);
    const trimmed = trimTrailingWhitespace(raw_line);
    const seed: u32 = if (hasSignificantChar(trimmed)) 0 else line_idx;
    const h = std.hash.XxHash32.hash(seed, trimmed);
    const bigram = bigrams.all[h % bigrams.all.len];
    assert(bigram.len == 2);
    return bigram;
}

fn trimTrailingWhitespace(line: []const u8) []const u8 {
    var end: usize = line.len;
    while (end > 0) {
        const c = line[end - 1];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            end -= 1;
        } else break;
    }
    return line[0..end];
}

fn hasSignificantChar(line: []const u8) bool {
    for (line) |c| {
        if (std.ascii.isAlphanumeric(c)) return true;
    }
    return false;
}

/// Write a hashline-prefixed line to the buffer: `LINE+HASH|TEXT`.
pub fn writeHashLine(
    gpa: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    line_number: u32,
    line: []const u8,
) !void {
    assert(line_number >= 1);
    const hash = computeLineHash(line_number, line);
    try buffer.print(gpa, "{d}{s}{c}{s}", .{ line_number, hash, body_sep, line });
}

/// Hashline-format every line of `text`. Lines are joined with `\n`.
pub fn formatHashLines(gpa: std.mem.Allocator, text: []const u8, start_line: u32) ![]u8 {
    assert(start_line >= 1);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    var iter = std.mem.splitScalar(u8, text, '\n');
    var line_idx = start_line;
    var first = true;
    while (iter.next()) |line| {
        if (!first) try buffer.append(gpa, '\n');
        first = false;
        try writeHashLine(gpa, &buffer, line_idx, line);
        line_idx += 1;
    }
    return buffer.toOwnedSlice(gpa);
}

test "computeLineHash returns a 2-char bigram" {
    const hash = computeLineHash(1, "function foo() {");
    try std.testing.expectEqual(@as(usize, 2), hash.len);
    try std.testing.expect(std.ascii.isLower(hash[0]));
    try std.testing.expect(std.ascii.isLower(hash[1]));
}

test "computeLineHash is stable across calls" {
    const a = computeLineHash(7, "    return result;");
    const b = computeLineHash(7, "    return result;");
    try std.testing.expectEqualSlices(u8, a, b);
}

test "trailing whitespace does not affect the hash" {
    const clean = computeLineHash(3, "let x = 1;");
    const padded = computeLineHash(3, "let x = 1;   \t\r");
    try std.testing.expectEqualSlices(u8, clean, padded);
}

test "blank lines distinguish by line number" {
    const at_one = computeLineHash(1, "");
    const at_two = computeLineHash(2, "");
    try std.testing.expect(!std.mem.eql(u8, at_one, at_two));
}

test "formatHashLines prefixes every line" {
    const gpa = std.testing.allocator;
    const out = try formatHashLines(gpa, "alpha\nbeta\ngamma", 1);
    defer gpa.free(out);
    var iter = std.mem.splitScalar(u8, out, '\n');
    var index: u32 = 1;
    while (iter.next()) |line| : (index += 1) {
        try std.testing.expect(line.len >= 5); // "<n><hh>|" + body
        try std.testing.expectEqual(@as(u8, body_sep), line[std.mem.indexOfScalar(u8, line, body_sep).?]);
    }
    try std.testing.expectEqual(@as(u32, 4), index);
}
