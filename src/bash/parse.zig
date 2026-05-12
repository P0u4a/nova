const std = @import("std");

const assert = std.debug.assert;

pub const Redirect = struct {
    kind: Kind,
    target: []const u8,

    pub const Kind = enum { input, output, append };
};

pub const Simple = struct {
    argv: []const []const u8,
    redirects: []const Redirect,
    span_start: u32,
    span_end: u32,
};

pub const Pipeline = struct {
    simples: []const Simple,
    span_start: u32,
    span_end: u32,
};

pub const Separator = enum { semicolon, and_and, or_or };

pub const Command = struct {
    pipelines: []const Pipeline,
    separators: []const Separator,
};

pub const Error = error{
    UnsupportedSyntax,
    UnterminatedQuote,
    UnexpectedToken,
    EmptyCommand,
    OutOfMemory,
};

/// Parse `command` into an AST. Allocates AST nodes from `arena`.
/// Returns `Error.UnsupportedSyntax` for any shell feature we do not handle
/// (expansion, subshells, fd manipulation, background, heredocs, globbing).
pub fn parse(arena: std.mem.Allocator, command: []const u8) Error!Command {
    assert(command.len > 0);
    var parser: Parser = .{ .arena = arena, .src = command, .pos = 0 };
    return parser.parseCommand();
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: u32,

    fn parseCommand(self: *Parser) Error!Command {
        var pipelines: std.ArrayList(Pipeline) = .empty;
        var separators: std.ArrayList(Separator) = .empty;
        const first = try self.parsePipeline();
        try pipelines.append(self.arena, first);
        while (true) {
            self.skipWhitespace();
            if (self.pos == self.src.len) break;
            const separator = try self.readSeparator();
            try separators.append(self.arena, separator);
            const next = try self.parsePipeline();
            try pipelines.append(self.arena, next);
        }
        assert(pipelines.items.len == separators.items.len + 1);
        return .{
            .pipelines = try pipelines.toOwnedSlice(self.arena),
            .separators = try separators.toOwnedSlice(self.arena),
        };
    }

    fn parsePipeline(self: *Parser) Error!Pipeline {
        var simples: std.ArrayList(Simple) = .empty;
        const start = self.pos;
        const first = try self.parseSimple();
        try simples.append(self.arena, first);
        while (true) {
            self.skipWhitespace();
            if (!self.peekChar('|')) break;
            if (self.peekTwo('|', '|')) break; // `||` is a separator, not a pipe.
            self.pos += 1;
            const next = try self.parseSimple();
            try simples.append(self.arena, next);
        }
        assert(simples.items.len >= 1);
        return .{
            .simples = try simples.toOwnedSlice(self.arena),
            .span_start = start,
            .span_end = self.pos,
        };
    }

    fn parseSimple(self: *Parser) Error!Simple {
        self.skipWhitespace();
        var argv: std.ArrayList([]const u8) = .empty;
        var redirects: std.ArrayList(Redirect) = .empty;
        const start = self.pos;
        while (true) {
            self.skipWhitespace();
            if (self.atSimpleTerminator()) break;
            if (try self.tryReadRedirect()) |redir| {
                try redirects.append(self.arena, redir);
                continue;
            }
            const word = try self.readWord();
            try argv.append(self.arena, word);
        }
        if (argv.items.len == 0) return Error.EmptyCommand;
        return .{
            .argv = try argv.toOwnedSlice(self.arena),
            .redirects = try redirects.toOwnedSlice(self.arena),
            .span_start = start,
            .span_end = self.pos,
        };
    }

    fn atSimpleTerminator(self: *const Parser) bool {
        if (self.pos == self.src.len) return true;
        const c = self.src[self.pos];
        if (c == '|') return true;
        if (c == ';') return true;
        if (c == '&') return true;
        return false;
    }

    fn readSeparator(self: *Parser) Error!Separator {
        assert(self.pos < self.src.len);
        const c = self.src[self.pos];
        if (c == ';') {
            self.pos += 1;
            return .semicolon;
        }
        if (self.peekTwo('&', '&')) {
            self.pos += 2;
            return .and_and;
        }
        if (self.peekTwo('|', '|')) {
            self.pos += 2;
            return .or_or;
        }
        if (c == '&') return Error.UnsupportedSyntax; // background `&`
        return Error.UnexpectedToken;
    }

    fn tryReadRedirect(self: *Parser) Error!?Redirect {
        if (self.pos == self.src.len) return null;
        const c = self.src[self.pos];
        const kind: Redirect.Kind = blk: {
            if (c == '<') {
                if (self.peekTwo('<', '<')) return Error.UnsupportedSyntax; // heredoc.
                self.pos += 1;
                break :blk .input;
            }
            if (c == '>') {
                if (self.peekTwo('>', '>')) {
                    self.pos += 2;
                    break :blk .append;
                }
                self.pos += 1;
                break :blk .output;
            }
            return null;
        };
        self.skipWhitespace();
        if (self.pos == self.src.len) return Error.UnexpectedToken;
        const target = try self.readWord();
        return .{ .kind = kind, .target = target };
    }

    fn readWord(self: *Parser) Error![]const u8 {
        var scratch: std.ArrayList(u8) = .empty;
        var produced = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isWordTerminator(c)) break;
            if (isUnsupportedMeta(c)) return Error.UnsupportedSyntax;
            switch (c) {
                '\'' => try self.readSingleQuoted(&scratch),
                '"' => try self.readDoubleQuoted(&scratch),
                '\\' => try self.readBackslashEscape(&scratch),
                else => {
                    try scratch.append(self.arena, c);
                    self.pos += 1;
                },
            }
            produced = true;
        }
        if (!produced) return Error.UnexpectedToken;
        return try scratch.toOwnedSlice(self.arena);
    }

    fn readSingleQuoted(self: *Parser, scratch: *std.ArrayList(u8)) Error!void {
        assert(self.src[self.pos] == '\'');
        self.pos += 1;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '\'') {
                self.pos += 1;
                return;
            }
            try scratch.append(self.arena, c);
        }
        return Error.UnterminatedQuote;
    }

    fn readDoubleQuoted(self: *Parser, scratch: *std.ArrayList(u8)) Error!void {
        assert(self.src[self.pos] == '"');
        self.pos += 1;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                return;
            }
            if (c == '$' or c == '`') return Error.UnsupportedSyntax;
            if (c == '\\') {
                if (self.pos + 1 == self.src.len) return Error.UnterminatedQuote;
                const next = self.src[self.pos + 1];
                if (next == '"' or next == '\\' or next == '`' or next == '$' or next == '\n') {
                    try scratch.append(self.arena, next);
                    self.pos += 2;
                    continue;
                }
                try scratch.append(self.arena, c);
                self.pos += 1;
                continue;
            }
            try scratch.append(self.arena, c);
            self.pos += 1;
        }
        return Error.UnterminatedQuote;
    }

    fn readBackslashEscape(self: *Parser, scratch: *std.ArrayList(u8)) Error!void {
        assert(self.src[self.pos] == '\\');
        if (self.pos + 1 == self.src.len) return Error.UnexpectedToken;
        try scratch.append(self.arena, self.src[self.pos + 1]);
        self.pos += 2;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        }
    }

    fn peekChar(self: *const Parser, c: u8) bool {
        if (self.pos >= self.src.len) return false;
        return self.src[self.pos] == c;
    }

    fn peekTwo(self: *const Parser, a: u8, b: u8) bool {
        if (self.pos + 1 >= self.src.len) return false;
        return self.src[self.pos] == a and self.src[self.pos + 1] == b;
    }
};

fn isWordTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
        c == '|' or c == '&' or c == ';' or c == '<' or c == '>';
}

fn isUnsupportedMeta(c: u8) bool {
    // `$` -> expansion, `` ` `` -> command substitution,
    // `(`/`)` -> subshell, `{`/`}` -> brace expansion,
    // `*`/`?`/`[` -> globbing (bash would expand these, our handlers won't).
    return c == '$' or c == '`' or c == '(' or c == ')' or
        c == '{' or c == '}' or c == '*' or c == '?' or c == '[';
}

test "single simple command" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cmd = try parse(arena, "cat foo.txt");
    try std.testing.expectEqual(@as(usize, 1), cmd.pipelines.len);
    try std.testing.expectEqual(@as(usize, 0), cmd.separators.len);
    const pipeline = cmd.pipelines[0];
    try std.testing.expectEqual(@as(usize, 1), pipeline.simples.len);
    const simple = pipeline.simples[0];
    try std.testing.expectEqual(@as(usize, 2), simple.argv.len);
    try std.testing.expectEqualStrings("cat", simple.argv[0]);
    try std.testing.expectEqualStrings("foo.txt", simple.argv[1]);
}

test "pipeline with two stages" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cmd = try parse(arena, "cat a.txt | head -n 5");
    const pipeline = cmd.pipelines[0];
    try std.testing.expectEqual(@as(usize, 2), pipeline.simples.len);
    try std.testing.expectEqualStrings("cat", pipeline.simples[0].argv[0]);
    try std.testing.expectEqualStrings("head", pipeline.simples[1].argv[0]);
    try std.testing.expectEqualStrings("-n", pipeline.simples[1].argv[1]);
    try std.testing.expectEqualStrings("5", pipeline.simples[1].argv[2]);
}

test "sequential separators" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cmd = try parse(arena, "ls ; cat foo && grep bar baz || true");
    try std.testing.expectEqual(@as(usize, 4), cmd.pipelines.len);
    try std.testing.expectEqual(@as(usize, 3), cmd.separators.len);
    try std.testing.expectEqual(Separator.semicolon, cmd.separators[0]);
    try std.testing.expectEqual(Separator.and_and, cmd.separators[1]);
    try std.testing.expectEqual(Separator.or_or, cmd.separators[2]);
}

test "quoted arguments" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cmd = try parse(arena, "sed -n '1,10p' some-file.txt");
    const simple = cmd.pipelines[0].simples[0];
    try std.testing.expectEqualStrings("sed", simple.argv[0]);
    try std.testing.expectEqualStrings("-n", simple.argv[1]);
    try std.testing.expectEqualStrings("1,10p", simple.argv[2]);
    try std.testing.expectEqualStrings("some-file.txt", simple.argv[3]);
}

test "double quotes with escapes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cmd = try parse(arena, "echo \"hello \\\"world\\\"\"");
    const simple = cmd.pipelines[0].simples[0];
    try std.testing.expectEqualStrings("echo", simple.argv[0]);
    try std.testing.expectEqualStrings("hello \"world\"", simple.argv[1]);
}

test "redirects on simple command" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cmd = try parse(arena, "cat foo > bar.txt");
    const simple = cmd.pipelines[0].simples[0];
    try std.testing.expectEqual(@as(usize, 2), simple.argv.len);
    try std.testing.expectEqual(@as(usize, 1), simple.redirects.len);
    try std.testing.expectEqual(Redirect.Kind.output, simple.redirects[0].kind);
    try std.testing.expectEqualStrings("bar.txt", simple.redirects[0].target);
}

test "append redirect" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cmd = try parse(arena, "cat foo >> bar.txt");
    try std.testing.expectEqual(Redirect.Kind.append, cmd.pipelines[0].simples[0].redirects[0].kind);
}

test "expansion is rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(Error.UnsupportedSyntax, parse(arena, "echo $HOME"));
    try std.testing.expectError(Error.UnsupportedSyntax, parse(arena, "echo `pwd`"));
    try std.testing.expectError(Error.UnsupportedSyntax, parse(arena, "echo $(pwd)"));
    try std.testing.expectError(Error.UnsupportedSyntax, parse(arena, "echo *.zig"));
}

test "background ampersand is rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(Error.UnsupportedSyntax, parse(arena, "sleep 5 &"));
}

test "heredoc is rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(Error.UnsupportedSyntax, parse(arena, "cat <<EOF"));
}
