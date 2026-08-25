# Nova Architecture

## Interface

Nova is headless. Running `nova` starts a JSON-RPC server: commands arrive as JSON objects on stdin, one per line; responses and events leave on stdout, one per line. There is no TUI — clients render however they like.

The wire contract follows Pi's RPC mode, so a client written against `pi --mode rpc` works against `nova`. Framing is strict JSONL with LF as the only delimiter (a trailing `\r` is stripped on input); `U+2028`/`U+2029` are *not* delimiters, because they are legal inside JSON strings. A record longer than 8 MiB is discarded by itself: the client is told once and parsing resumes at the next newline, rather than the whole session ending over one bad frame.

See [RPC.md](RPC.md) for the implemented surface.

## LLM Gateway

Nova accepts any OpenAI-compatible endpoint (either `/completions` or `/responses`).

We try to normalise the request to a shape that is most compatible with the target provider.

## Agent Tools

Nova exposes the following tools:

- `bash` — run a command. The general-purpose escape hatch, and how the agent reads files (`cat -n`).
- `edit` — exact-text replacement in one file.
- `write` — create a file or replace it entirely.
- `find` — locate files by path.
- `grep` — search file contents.
- `view_image` — look at an image file.
- `zoom` — magnify a region of an image, cropped from the original at full resolution.

The registry in `src/tools.zig` is the single source of truth for what exists. A tool has no display hook: its only output is the observation the model reads, which the RPC layer forwards verbatim as the tool result's content. Structured extras (`edit` and `write` return the diff they produced) travel in the result's `details` — data, not presentation.

`bash` has some middleware written for it that makes it friendlier for agent use. For example, large outputs from a `cat` command are written to a temp file and the agent is told the full output is in that file if needed.

### File Editing

The interface for `edit` and `write` is adapted from Pi. `edit` supports batched replacements: every `old_text` must match exactly once, all of them are matched against the *original* file rather than each other's output, and everything is validated before a single byte is written — so a rejected edit leaves the file byte-identical and can be retried against unchanged content. Line endings and a byte-order mark survive the round trip.

Matching tries the file verbatim first (after normalizing line endings) and only then retries with whitespace and Unicode punctuation folded, because that is how models actually misquote text. A fuzzy match rewrites only the lines it touched and says so in its result. The mechanics live in `src/tools/edit_text.zig`, apart from the file I/O in `src/tools/edit.zig`.

### Images

A path is a claim; the bytes are the fact. `src/image.zig` identifies an image from its own header — PNG, JPEG, GIF, WebP, BMP — so a GIF named `.png` is labelled correctly and a text file named `.png` is not sent as an image at all. The `@`-mention path, `view_image` and `zoom` all go through it.

Images reach the model two ways. A human attaches them: the RPC `images` field on `prompt`/`steer`/`follow_up`, or an `@shot.png` mention, which become image blocks on the user message. Or the agent asks to see one, with `view_image` and then `zoom` — the only route, because `cat` on an image yields binary garbage and there is no `read` tool.

Getting a tool's image onto the wire takes a detour, because **neither OpenAI dialect will carry an image in a tool result** — Chat Completions requires a `tool` message's content to be text, and `function_call_output.output` is a string. So the adapters emit the run of tool results text-only and then synthesise a following **user** message holding their images (`writeAttachedImages` in `openai_compatible.zig` and `responses_core.zig`). This is what Pi does. The tool result's own text still has to carry the facts — type, path, size, and the dimensions `zoom` depends on — because that text is what stays in history as the `tool` message; the image only exists in a user message the adapter synthesises fresh each request.

### Zoom

A model sees an image as a grid of patches. Anything finer than a patch — a tick label, two lines eight pixels apart — is not there to read however carefully it looks. `zoom` crops that region out of the file at full resolution and scales it up, which is the difference between guessing at a chart and reading it. The design follows [Anthropic's crop-tool cookbook](https://platform.claude.com/cookbook/multimodal-crop-tool).

That only works if the model and Nova agree on what "pixel (400, 300)" means, which is why `image.view` decides the size an image is sent at instead of letting the provider downscale invisibly: a PNG over `raster.view_edge_max` (1568 on its long edge) is shrunk here, `view_image` reports the exact dimensions and the coordinate convention, and `zoom` recomputes the identical view from the file and maps the box back onto the original. No state travels between the two calls.

One deliberate difference from the cookbook: the region is addressed by **path**, not by an index into the conversation's images. Nova keeps no image registry, and a path is both stateless and more useful — the agent can zoom into a file it never viewed. Coordinates are clamped rather than rejected (a model's box is an estimate, and being three pixels over the edge is not a mistake worth failing on), and the result reports the box it actually used, the size of the region in the original, and what it was magnified to — so the model can tell whether it was clamped and whether zooming again will help.

Magnification is capped at `raster.zoom_scale_max` as well as by the view budget, because blowing a 3x3 region up to 1568x1568 spends the whole image budget on nine enormous squares.

### Pixels

Cropping and scaling need real pixels, so `src/image/png.zig` is a PNG decoder and encoder: zlib via `std.compress.flate`, the five scanline filters, and the usual pixel layouts (1/2/4/8/16-bit grayscale, 8/16-bit RGB and RGBA, indexed with `tRNS`), everything normalised to RGBA8. Interlaced files are refused rather than mis-decoded. `src/image/raster.zig` does the geometry — a box filter for shrinking, because point-sampling a downscale drops whole rows of thin chart lines, and bilinear for magnifying, because nearest-neighbour turns antialiased glyphs into blocks.

PNG only, and deliberately: screenshots, rendered charts and UI captures are overwhelmingly PNG, while baseline JPEG would mean Huffman tables, an IDCT and chroma upsampling for a format that mostly shows up as photographs. Other formats still *view* — they go out untouched — but `zoom` refuses them and says to convert with `bash` first.

Nothing is upscaled to fill space and no format is re-encoded to save it. An attached image stays in history and is re-sent with every later request, so an image still over 5 MiB after the view resize is refused with a message saying to shrink it, rather than quietly inflating every subsequent prompt.

### Search

`find` and `grep` are backed by [fff](https://github.com/dmtrKovalenko/fff) through its C ABI (`src/search.zig`), which keeps a warm index of the project. `grep` takes a **list** of patterns and searches them in one pass (`fff_multi_grep`), falling back to `fff_live_grep` for a single regex. `find` matches fuzzily against indexed paths rather than by glob, because that is what the index offers — a strict glob is a `bash` job.

When the fff library isn't built or is still scanning, both degrade to `rg`/`grep`/`find` through a shell and the result says so.

## Steering

Steering is done by enqueuing messages into a bounded queue. By default, the front of the queue is popped and appended to the conversation after the agent's turn is finished. You can also choose to _steer_ instead and send the queued message after the next tool call is done. If the agent stops and there are still messages in the queue we flush all the messages and append them into the conversation.

Over RPC this is the `steer` / `follow_up` commands, and the `streamingBehavior` field on `prompt`.

## Sessions

Conversations persist to one SQLite database at `~/.nova/sessions.sqlite`, shared by every project and every running instance. Entries form a parent-linked tree; the in-memory message list is a derived projection of the active path, rebuilt with a single recursive CTE.

Writes are queued and drained by a background thread so a streaming turn never blocks on disk. Reads go through a **second, read-only connection**, which WAL allows to run concurrently with that writer — a read flushes the queue and then reads, rather than stopping the writer.

## Bash auto-review

We have fine-tuned a ModernBERT base model on a corpus of over 3000 bash commands and classified each command as either safe or unsafe. We run this model on every bash tool call the agent makes. A flagged command is rejected and the model is told to try something else — the gate fails closed, since there is no interactive prompt to defer to. A client that wants to make the decision itself can attach an approval hook (`Agent.bash_approval`); exposing that over RPC is not implemented yet. Thanks to the efficient architecture of ModernBERT (i.e. Alternating Attention) and its small size the performance overhead of making these inference calls is negligible.
