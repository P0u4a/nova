# Nova Architecture

## Agent Tools

Nova exposes the following tools:

- `read_file`
- `write_file`
- `edit_file`
- `search_codebase`
- `bash`

`read_file` emits content-hash anchors (`LINE+HASH|TEXT`) that `edit_file` consumes in hashline patch documents.

`search_codebase` is reserved for a future code-search implementation.

`bash` works as you would expect.
