# RPC

`nova` speaks JSON over stdin/stdout. The contract follows [Pi's RPC mode](https://github.com/earendil-works/pi).

## Framing

- Commands: one JSON object per line on stdin.
- Responses and events: one JSON object per line on stdout.
- LF (`\n`) is the only record delimiter. A trailing `\r` is accepted and stripped.
- Do **not** split on `U+2028`/`U+2029` — they are legal inside JSON strings. Node's `readline` is not protocol-compliant for this reason.
- A record longer than 8 MiB is discarded on its own: one error response is sent and parsing resumes at the next newline. One oversized frame does not end the session.

Every command may carry an `id`; the matching response echoes it.

## Attaching images

`prompt`, `steer` and `follow_up` all accept an optional `images` array, in Pi's shape:

```json
{"type":"prompt","message":"why is this button misaligned?","images":[
  {"type":"image","data":"<base64>","mimeType":"image/png"}
]}
```

`mimeType` must be an `image/*` type and `data` must decode as base64; `mime_type` is accepted as a spelling alias. Both are validated on arrival rather than at the provider, so a bad attachment is rejected with a message that names the problem. At most 16 images per message, each at most 5 MiB decoded — attachments are not downscaled, and an image stays in the conversation and is re-sent with every later request, so an oversized one is refused rather than silently inflating every prompt that follows.

The agent can produce images too: `view_image` attaches one and `zoom` attaches a magnified crop, and it arrives as a second block in that tool result's `content` (`{"type":"image","data":...,"mimeType":...}`) — the same shape you send, so a client can hand it straight back.

## Implemented commands

| Command | Notes |
|---|---|
| `prompt` | `{"type":"prompt","message":"..."}`, plus optional `images`. While streaming, requires `streamingBehavior` of `"steer"` or `"followUp"`, else the command is rejected. |
| `steer` | Queue a message (and optional `images`) for delivery after the current tool batch. |
| `follow_up` | Queue a message (and optional `images`) for delivery once the agent stops. |
| `abort` | Cancel the running turn and clear the queue. |
| `get_state` | `isStreaming`, `model`, `messageCount`, `pendingMessageCount`, `sessionId`. |
| `get_messages` | The conversation, excluding the system prompt. |
| `get_last_assistant_text` | The most recent non-empty assistant text, or null. |
| `new_session` | Start a fresh conversation, keeping the model, skills and system prompt. Rejected while streaming. |
| `switch_session` | Resume an existing session: `{"sessionId":"..."}`. Rejected while streaming. |
| `set_model` | `{"provider":"ollama","modelId":"llama3"}`. Reconnects the client; the conversation is untouched. Rejected while streaming. |
| `get_available_models` | Every model the config declares, as `{provider, id}`. |
| `get_commands` | Returns an empty list — there is no extension system yet. |

`success: true` on `prompt` means accepted or queued, not completed. Failures after acceptance arrive on the event stream, not as a second response.

## Implemented events

| Event | Notes |
|---|---|
| `agent_start` | A run begins. |
| `turn_start` | One assistant response begins. |
| `turn_end` | That response finished: `turnIndex`, `message` (the assistant message), `toolResults` (the results of the tools it called). |
| `message_update` | Streaming deltas; see below. |
| `message_end` | Emitted with `stopReason: "error"` when a turn fails. |
| `tool_execution_start` | `toolCallId`, `toolName`, `args` (an object when the arguments parse, else a string). |
| `tool_execution_end` | `result.content[]` (a text block, plus an image block when the tool attached one), optional `result.details`, `isError`. |
| `queue_update` | Pending message count changed. |
| `compaction_end` | History was compacted; carries before/after token estimates. |
| `agent_end` | The run finished; carries `messages`, the conversation excluding the system prompt. |
| `agent_settled` | Nothing further will happen automatically. |

### message_update

`assistantMessageEvent` carries `text_start`/`text_delta`/`text_end`, `thinking_*`, and `toolcall_*`, each tagged with a `contentIndex`. Nova's agent reports deltas without block boundaries, so the RPC layer synthesises them: a block is closed before the next opens, and `*_end` carries the complete assembled content (`content` for text/thinking, `toolCall` for a call). Treat the `*_end` payload as authoritative rather than accumulating deltas yourself.

A client that only wants the finished answer does not need these at all — `turn_end` carries the assembled message, and `agent_end` the whole conversation. Prefer them to a `get_messages` round-trip after `agent_end`, which races a queued follow-up turn that may already have started.
