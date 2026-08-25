# Nova

The coding agent for shipping to the stars.

> Alpha software. Expect things to break.

# Quick Start

Git clone `fff` (used for file search) into `third_party/` and build it. Specific instructions
in [vendor/fff/README.md](vendor/fff/README.md).

Download `P0u4a/ModernBERT-bash-classifier` from huggingface (used for classifying the bash tool calls). Easiest way is with huggingface cli.

```bash
hf download P0u4a/ModernBERT-bash-classifier
```

And export the model to ONNX

```bash
cd vendor/local-models
uv run python export_onnx.py --model-dir /path/to/model
```

Then

```sh
zig build
```

Add the binary (`zig-out/bin/nova`) to your PATH so you can invoke it from anywhere.

# Usage

Nova is headless. Running `nova` starts a JSON-RPC server on stdin/stdout: send it
commands as JSON lines, read events back as JSON lines.

```sh
printf '%s\n' '{"type":"prompt","message":"what does src/agent.zig do?"}' | nova
```

Integrate this in apps and TUIs.

The protocol follows Pi's RPC mode. See [docs/RPC.md](docs/RPC.md) for the commands and events Nova supports.
