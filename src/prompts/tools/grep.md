Search file contents across the project, using a warm index. Respects `.gitignore`.

Prefer this over `rg`/`grep` through bash: it searches a maintained index instead of walking the tree, and it takes many patterns in one pass.

- `patterns` takes a **list**. Every line matching any pattern is reported, in one search. When you have several things to look for, pass them together rather than making a call per pattern.
- Patterns are literal text by default. Set `regex: true` for a regular expression — that works with a single pattern only, so combine alternatives into one expression if you need it.
- `glob` narrows the files searched: `*.zig`, `*.{ts,tsx}`, `/src/`.
- `context` includes surrounding lines. Context lines are printed with `-` between path and line number; match lines use `:`.
- Output is capped by `limit` (default 50). When more matches exist, the result ends with a cursor — pass it back as `cursor` for the next page rather than re-running with a bigger limit.
- Matching file paths are what `find` is for; this searches inside files.

## Examples

Where is something used:

```json
{"patterns": ["keepRef"]}
```

Several call sites at once, scoped by file type:

```json
{"patterns": ["snapshotNow", "dropSessionRefs", "last_snapshot_tree"], "glob": "*.zig"}
```

With context, to read the surrounding lines:

```json
{"patterns": ["fn deinit"], "glob": "*.zig", "context": 3}
```

A regular expression:

```json
{"patterns": ["fn (init|deinit)\\("], "regex": true}
```
