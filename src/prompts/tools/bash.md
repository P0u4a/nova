Run a shell command.

- Set the working directory with the `cwd` param, not `cd dir && ...` because each call starts a fresh shell.
- Pass values via `env: { NAME: "..." }` for multiline or complex values. Reference them as `"$NAME"`.
- Quote every expansion: `"$var"`, `"$(cmd)"`, `"${arr[@]}"`.
- Default timeout is 10 seconds. Raise it with the `timeout` parameter when a command needs longer.
- Prefer targeted commands (`rg`, `find`, `git diff --stat`, `head`, `tail`) over dumping large files or full build logs.
- Bash output may be truncated. If output is truncated, use the reported full-output path to read the rest or rerun with a narrower command.

## Long-running commands

- For commands that take a long time or never return on their own — builds, dev servers, watchers, `tail -f` — set `run_in_background: true`. The call returns immediately with a job id, pid, and a log file path instead of blocking.
- The command keeps running after the call returns. Its eventual exit is delivered to you as a message; do not poll in a busy loop waiting for it.
- To check on a background job meanwhile, read its log file (e.g. `tail -n 50 <path>`) or use `ps`/`taskkill` with the reported pid. The log path stays valid for the life of the job.
- `timeout` is ignored for background commands. Use a normal (foreground) call for anything you need the output of right away.

## Error handling

- A non-zero exit code is returned in the result. For multi-step commands, chain with `&&` or start scripts with `set -euo pipefail`.
- Commands that may legitimately fail should end with `|| true` so later steps still run.

## Useful patterns

```bash
# Sequential steps. Stop on first failure.
npm run lint && npm test

# Read a file, with line numbers.
cat -n src/main.ts

# Read part of a large file.
sed -n '120,180p' src/main.ts

# Inspect a directory.
ls -la src

# Summarize repository changes.
git diff --stat && git status --short

# Run the build and tests.
npm run lint && npm test
```

Use the `grep` tool to search contents and the `find` tool to locate files — both query a maintained index. Use `edit` and `write` to change files rather than `sed -i` or a redirect, so a bad match fails cleanly instead of corrupting the file.

## Pitfalls

- `$var` unquoted splits on spaces and glob characters. Use `"$var"`.
- `if [ -n $var ]` breaks when `$var` is empty. Use `if [ -n "$var" ]`.
- `for f in $(ls *.rs)` breaks on spaces and newlines. Use shell globs instead.
- `cd dir && cmd` resets next call. Use the `cwd` param.
- `cmd 2>&1 > file` only sends stdout to the file. Use `cmd > file 2>&1`.
