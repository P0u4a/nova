Locate files by path, using a warm index. Respects `.gitignore`.

`query` is matched **fuzzily** against every indexed path and the best matches come first — it is not a glob. Characters must appear in order but need not be adjacent, so `toolsedit` finds `src/tools/edit.zig`.

- Use the distinctive part of the path you remember: `session writer`, `tools/edit`, `blackhole`.
- Directories are included, marked with a trailing `/`.
- Output is capped by `limit` (default 50); a truncated result ends with a cursor to pass back as `cursor`.
- To search file *contents*, use `grep`. To list a directory or match a strict glob, use `bash` (`ls`, `find`).

## Examples

```json
{"query": "session"}
```

```json
{"query": "tools/edit"}
```

```json
{"query": "prompts", "limit": 100}
```
