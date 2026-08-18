Replace exact text in a single file.

Each entry in `edits` is one replacement. `old_text` must appear **exactly once** in the file — if it appears more than once, the call is rejected and nothing is written; add surrounding lines until it is unique.

- Read the file first (`cat -n`, `grep`) and copy `old_text` verbatim: same indentation, same spacing, same line breaks.
- Every `old_text` is matched against the file as it is **now**, not against the result of the other edits in the same call. You never need to account for your own earlier edits.
- Edits must not overlap or nest. If two changes touch the same lines, merge them into one edit.
- Keep `old_text` to the smallest unique span. Do not paste a large unchanged region just to connect two distant changes — use two edits instead.
- `new_text` may be empty to delete the matched span.
- Everything is validated before anything is written: a rejected call leaves the file byte-identical, so it is safe to retry with a corrected `old_text`.
- The file's existing line endings and byte-order mark are preserved.

Use `write` instead when creating a new file or replacing a whole file. Use `bash` (`cat`) to read.

## Examples

One replacement:

```json
{"path": "src/main.zig", "edits": [{"old_text": "const port = 8080;", "new_text": "const port = 3000;"}]}
```

Several at once (independent spans, one call):

```json
{"path": "src/server.ts", "edits": [
  {"old_text": "import { old } from \"./old\";", "new_text": "import { new } from \"./new\";"},
  {"old_text": "  return old(req);", "new_text": "  return new(req);"}
]}
```

Deleting a line:

```json
{"path": "src/main.zig", "edits": [{"old_text": "    std.debug.print(\"debug\\n\", .{});\n", "new_text": ""}]}
```
