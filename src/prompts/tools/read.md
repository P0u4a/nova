Reads the content at the specified filesystem path.

<instruction>
Use `read` for inspecting files and directories. Prefer it over `cat`, `head`, `tail`, `less`, `more`, `ls`, `sed -n`, or `awk NR` when the goal is inspection.

## Parameters

- `path` — file path (required). Append a selector for line ranges, raw mode, or conflict inspection.

## Selectors

| `path` suffix | Behavior |
| ------------- | -------- |
| _(omitted)_ | Read from the start, up to {{DEFAULT_LIMIT}} lines, with content-hash anchors. |
| `:50` | Read from line 50 onward with anchors. |
| `:50-200` | Read lines 50-200 with anchors. |
| `:50+150` | Read 150 lines starting at line 50 with anchors. |
| `:20+1` | Read exactly one line with an anchor. |
| `:raw` | Read verbatim text without anchors. |
| `:conflicts` | Return a one-line-per-block index of every merge conflict in the file. |

# Filesystem

- Reading a directory path returns a list of directory entries.
- Reading a file with an omitted or explicit line selector returns lines prefixed with content-hash anchors: `41th|def alpha():`.
- Use anchors exactly as shown when calling `edit_file`.
</instruction>

<critical>
- You MUST always include the `path` parameter — never call `read` with an empty argument object `{}`.
- For specific line ranges, append the selector to `path` (e.g. `path="src/foo.ts:50-200"`, `path="src/foo.ts:50+150"`).
- Do not pass separate `offset` or `limit` fields; line selection belongs in the `path` suffix.
</critical>
