# Monty LLM Prompt — Developer Guide

This guide explains how to use the Monty system prompt when integrating
Monty into an LLM-powered application.

## The system prompt

`monty-llm-prompt.txt` is the ready-to-use system prompt. Paste it
verbatim into your LLM's system prompt (or upload it as a reference file).
It tells the model what Monty supports, what it does not support, and how
to write correct code for the sandbox. Do not paraphrase it — the exact
wording is tested against real model behaviour.

## What to add on top

`monty-llm-prompt.txt` describes the base Monty runtime. Your application
almost certainly registers additional host functions and may configure
filesystem access or resource limits. Add a short supplemental block after
the base prompt describing your specific setup. Example:

```
## Available host functions

The following functions are registered in this session:

| Function | Returns | Description |
|----------|---------|-------------|
| `soliplex_list_servers()` | JSON `[{id}]` | All connected servers |
| `soliplex_list_rooms(server)` | JSON `[{id, name, description}]` | Rooms on a server |
| `soliplex_new_thread(server, room_id, message)` | JSON `{thread_id, run_id, response}` | Start conversation |
| `soliplex_reply_thread(server, room_id, thread_id, message)` | JSON `{thread_id, run_id, response}` | Continue conversation |
| `tmpl_render(template, context)` | String (NOT JSON) | Render Jinja2-style template |
| `msg_send(channel, message)` | None | Send to FIFO channel |
| `msg_recv(channel)` | String | Receive from FIFO channel (blocks) |

All host functions except `tmpl_render` return JSON strings — always
`json.loads()` the result.
```

## Key gotchas to reinforce

These rules are already in the system prompt, but are worth emphasising
in your own evals or fine-tuning data:

- **No subscript unpacking targets.** `a[i], a[j] = a[j], a[i]` raises
  `SyntaxError`. Use a temporary variable:
  `tmp = a[i]; a[i] = a[j]; a[j] = tmp`.
- **No bare `except` or `except Exception: pass`.** Silent catches hide
  host function failures and leave variables undefined on the next call.
- **No chained assignment.** `a = b = 1` is not supported.
- **`enumerate()` has no `start` kwarg.** Add the offset manually.
- **No `%` string formatting.** Use f-strings.
- **Last expression is the return value**, not `return`.

## Filesystem notes

Filesystem access is off by default. If your host enables it, the model
will use `pathlib.Path` as described in the system prompt. Files are
in-memory and scoped to the session unless the host mounts a real
directory. Files uploaded via host functions (e.g. `soliplex_upload_*`)
live on the server, not in the Monty filesystem — do not try to read
them with `Path()`.

## Error handling pattern

Encourage the model to propagate errors rather than swallowing them.
The sandbox's state persistence catches `NameError` for normal control
flow; all other exceptions should surface to the caller:

```python
# Good — specific catch, structured error value
try:
    data = json.loads(fetch_data(id))
except Exception as e:
    data = {"error": str(e), "success": False}

# Also good — let it propagate so the caller sees it
data = json.loads(fetch_data(id))
```
