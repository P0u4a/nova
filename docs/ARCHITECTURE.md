# Nova Architecture

# Design Decisions

## Bash as the singular tool

Only one tool (`bash`) is exposed to the agent. This is done for several reasons:

### Reduce the context usage from tool definitions

Tool definitions tend to be the bottleneck when it comes to context usage. Prior art has shown that bash can get you very far. There are certain things where it's not good enough out of the box, for example editing files or reading files with line numbers and other useful metadata. However, we can circumvent this by intercepting calls to `cat` `head` `tail`, etc. and provide a custom implementation that can be used by the agent. In fact, we do this for many of the UNIX commands. For cases where an existing unix command doesn't really make sense (e.g. editing a file or searching the web), we provide a custom CLI subcommand the agent can use, and inform it of its existence in the system prompt.

### Improve readability for users and composability for agents

Consider the scenario where the agent wants to search the web for some specific information about `zig`. In most harnesses you might seen an output like this:

```bash
Called web_search("zig docs")
```

```bash
Called Grep("std.Io")
```

Whereas in Nova, you would see:

```bash
$ web-search "zig docs" | grep "std.Io"
```

Not only is the latter easier to reason about for someone familiar with bash, but it's also more compact as it only takes up one line.

Additionally, it is evident how the agent can easily compose different subcommands together in a single tool call rather than two, which ultimately saves latency and token spend.

