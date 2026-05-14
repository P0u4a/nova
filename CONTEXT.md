# Nova Agent

Nova Agent is a coding agent harness.

## Language

**Display body**:
The human-facing rendered body of a tool result, separate from the LLM-visible `stdout`. Some tools emit one alongside their stdout — the LLM sees the terse stdout, the user sees the display body.
_Avoid_: "tool output" (ambiguous between stdout, stderr, and display body)

**Diff view**:
The display body emitted by `edit_file`. Line-numbered prefix-tagged lines (`+N`, `-N`, ` N`, `    ...`) rendered from the hashline patch and the original file content. Not a `git diff` and not produced by Myers — derived structurally from the patch's edit operations.
_Avoid_: "patch view" (we use "patch" for the hashline document itself)

**Expand-by-default tool**:
A tool whose finished result is rendered with its body visible immediately. Currently `edit_file` and `write_file`. Other tools' bodies stay collapsed until the user toggles them. Streaming-time stays collapsed for all tools regardless.

## Relationships

- An **Expand-by-default tool** emits a **Display body**, which becomes the body of its finished thread message.
- `edit_file`'s display body is a **Diff view**; `write_file`'s is the new file content verbatim.

## Example dialogue

> **Dev:** "When the model calls `edit_file`, the user sees the diff but the model just sees a confirmation — how?"
> **Maintainer:** "The tool emits both. `stdout` carries a terse confirmation that flows back to the LLM as the tool observation; a separate **display body** carrying the **diff view** is shown only to the user. Two channels, one tool."
