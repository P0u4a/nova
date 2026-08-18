Write a file, creating it if it does not exist and replacing it entirely if it does. Parent directories are created for you.

- `content` is the complete file. There is no append mode and no partial write.
- Pass `content: ""` to truncate a file to empty.
- Prefer `edit` for changing part of an existing file: rewriting a whole file to alter a few lines risks dropping content you did not intend to touch, and produces a far noisier diff for the human watching.

## Examples

```json
{"path": "src/config.json", "content": "{\n  \"port\": 3000\n}\n"}
```

```json
{"path": "docs/notes/design.md", "content": "# Design\n\nFirst draft.\n"}
```
