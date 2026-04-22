# Monty Sandbox — Prompt Rules for Code Generation

When an LLM generates Python code for the Monty sandbox, include these
rules in the system prompt or as an uploaded reference file.

## Core Rules

1. **All host functions return JSON strings.** Always `json.loads()` the result.
2. `import json` at the top of every program.
3. The last expression is the return value.
4. Return code in a `` ```monty``` `` fenced code block. No explanation outside it.
5. **Use `=` for assignment, NOT `:=`.** The walrus operator is not supported.
6. **No `open()`, `eval()`, `exec()`.** Use `Path().read_text()` for files.
7. **No dot attribute access on dicts.** Use `d["key"]` not `d.key`.
8. **`enumerate()` has no `start` kwarg.** Use `enumerate(x)` and add offset manually:
   `for i, v in enumerate(items): day = i + 1`
9. **No `%` string formatting.** Use f-strings or `str()` + concatenation:
   `f"Got {count} items"` or `"Got " + str(count) + " items"`
10. **No chained assignment.** `a = b = 1` is not supported. Use `a = 1` then `b = 1`.
11. **No `locals()`, `globals()`, `eval()`, `exec()`.** These are not available.
12. **Only call functions that exist.** Call `help()` first to see the list
    of available functions. If a function isn't shown by `help()`, it does
    not exist. Do NOT invent functions like `bb_dump()`, `oracle()`, or
    `confirm()` — they will raise `RuntimeError: Unknown function`.
13. **Write top-level code, not function definitions.** Do not use
    `def main():` or `return`. The last expression is the return value.
14. **Use `print()` for progress and debugging.** Print output is captured
    separately from the return value. Use `print()` to show intermediate
    steps, then put the final result as the last expression:

    ```monty
    print("Fetching rooms...")
    rooms = json.loads(soliplex_list_rooms("local"))
    print(f"Found {len(rooms)} rooms")
    # last expression = return value
    [r["name"] for r in rooms]
    ```

## Monty Sandbox Limitations

Monty is a **restricted Python interpreter**. It is NOT full CPython.

### Available standard library

- `json` — json.loads, json.dumps
- `math` — basic math functions
- `re` — regular expressions
- `pathlib` — Path (only in-memory filesystem)
- `datetime` — date, datetime (if OsCallHandler configured)
- `collections` — OrderedDict, defaultdict, Counter, namedtuple

### NOT available

- `os`, `sys`, `subprocess`, `shutil` — **no system access**
- `requests`, `urllib`, `http` — **no direct network** (use host functions)
- `threading`, `multiprocessing`, `asyncio` — **no concurrency**
- `pickle`, `shelve` — **no serialization beyond JSON**
- `sqlite3`, `csv` — not built in (use host functions if available)
- `typing`, `dataclasses` — limited support
- Any `pip` packages — nothing installable

### Key differences from CPython

- **No file I/O** except through `pathlib.Path` on the in-memory filesystem
- **No network** except through host functions (soliplex_*, http_fn, etc.)
- **No environment variables** — `os.environ` does not exist
- **No shell execution** — cannot run commands
- **Host functions ARE the I/O layer** — they replace what you'd normally
  do with `requests`, `subprocess`, `open()`, etc.

### What to use instead

| You want to... | Use this |
|----------------|----------|
| Make HTTP requests | `soliplex_new_thread()` or custom host fn |
| Read/write files | `pathlib.Path` (in-memory only) |
| Store key-value data | `msg_send()`/`msg_recv()` channels |
| Render templates | `tmpl_render()` |
| Get current time | `datetime.datetime.now()` (if configured) |
| Run shell commands | Not possible — use host functions |

## Error Handling

**Never use bare `except` or `except Exception: pass`.**

The Monty sandbox persists variables across calls. If a host function
fails (network error, server 500, timeout) and the error is silently
caught, the variable is left undefined. The next `execute()` call
sees `None` with no indication of what went wrong.

```python
# BAD — hides server errors, variable silently missing
try:
    data = json.loads(soliplex_new_thread("server", "room", "msg"))
except:
    pass

# BAD — same problem, catches everything
try:
    data = json.loads(soliplex_new_thread("server", "room", "msg"))
except Exception:
    pass

# GOOD — catch specific, preserve the error
try:
    data = json.loads(soliplex_new_thread("server", "room", "msg"))
except Exception as e:
    data = {"error": str(e), "success": False}

# GOOD — let it propagate (Monty returns the error to Dart)
data = json.loads(soliplex_new_thread("server", "room", "msg"))
```

**Why this matters:** The sandbox's state persistence layer catches
`NameError` (variable never assigned) to handle normal control flow.
Any other exception — `RuntimeError` from host function failures,
`json.JSONDecodeError` from bad data, `KeyError` from missing fields —
should either be handled explicitly or allowed to propagate so the
caller sees a clear error.

## Discovering Available Functions

Call `help()` to see all registered host functions:

```monty
help()  # lists all available functions with descriptions
```

Call `help("function_name")` for detailed parameter info:

```monty
help("soliplex_new_thread")  # shows params, types, descriptions
```

Use this when you're unsure what functions are available or what
parameters they take. The `help()` output is always up-to-date with
the actual registered functions.

## Host Function Patterns

### All returns are JSON strings

```python
import json

# Every host function returns a string — decode it
servers = json.loads(soliplex_list_servers())        # -> list of dicts
rooms = json.loads(soliplex_list_rooms("server"))    # -> list of dicts
room = json.loads(soliplex_get_room("server", "id")) # -> dict
```

### Conversation flow

```python
import json

# Start
t = json.loads(soliplex_new_thread("server", "room", "Hello"))
thread_id = t["thread_id"]
response = t["response"]

# Continue (include thread_id)
t2 = json.loads(soliplex_reply_thread("server", "room", thread_id, "More"))
response2 = t2["response"]
```

### Template rendering

```python
# tmpl_render returns a string directly (NOT JSON)
rendered = tmpl_render("Hello {{ name }}!", {"name": "World"})
# rendered == "Hello World!" — no json.loads() needed
```

### Message bus

```python
# msg_send returns None, msg_recv blocks until message available
msg_send("channel", "data")
result = msg_recv("channel")  # -> "data"
```

### Filesystem

```python
from pathlib import Path

Path("/cache").mkdir(parents=True, exist_ok=True)
Path("/cache/data.json").write_text(json.dumps(data))
cached = json.loads(Path("/cache/data.json").read_text())
```

## Available Host Functions

### Soliplex — Server Communication

| Function | Returns | Description |
|----------|---------|-------------|
| `soliplex_list_servers()` | JSON `[{id}]` | All connected servers |
| `soliplex_list_rooms(server)` | JSON `[{id, name, description}]` | Rooms on a server |
| `soliplex_get_room(server, room_id)` | JSON `{id, name, skills, tools, ...}` | Room config |
| `soliplex_new_thread(server, room_id, message)` | JSON `{thread_id, run_id, response}` | Start conversation |
| `soliplex_reply_thread(server, room_id, thread_id, message)` | JSON `{thread_id, run_id, response}` | Continue conversation |
| `soliplex_list_threads(server, room_id)` | JSON `[{id, name, created_at}]` | List threads |
| `soliplex_upload_file(server, room_id, filename, content)` | JSON `{uploaded, room_id}` | Upload to room |
| `soliplex_upload_to_thread(server, room_id, thread_id, filename, content)` | JSON `{uploaded, thread_id}` | Upload to thread |
| `soliplex_get_mcp_token(server, room_id)` | JSON `{mcp_token}` | MCP access token |
| `soliplex_get_documents(server, room_id)` | JSON `[{id, title, uri}]` | RAG documents |

### Template Engine (Jinja2-style)

| Function | Returns | Description |
|----------|---------|-------------|
| `tmpl_render(template, context)` | String (NOT JSON) | Render template with variables |

### Message Bus (FIFO queues)

| Function | Returns | Description |
|----------|---------|-------------|
| `msg_send(channel, message)` | None | Send to channel |
| `msg_recv(channel)` | String | Receive (blocks) |
| `msg_peek(channel)` | String or None | Peek (non-blocking) |

### Filesystem (in-memory sandbox)

Standard Python `pathlib.Path` — write, read, mkdir, exists. Files
persist within a session but not across sessions.

**Important:** Files uploaded via `soliplex_upload_to_thread()` are NOT
in the monty sandbox filesystem. They live on the server. The monty
filesystem is a separate in-memory space. Do NOT try to read uploaded
files with `Path()` — embed the data directly in your code instead.

**No `open()`.** Use `Path("/file").read_text()` and
`Path("/file").write_text(data)` for the sandbox filesystem.

## Complete Example

```monty
import json
from pathlib import Path

# 1. Discover
servers = json.loads(soliplex_list_servers())
report = {}

for s in servers:
    sid = s["id"]
    rooms = json.loads(soliplex_list_rooms(sid))

    skilled = []
    for room in rooms:
        config = json.loads(soliplex_get_room(sid, room["id"]))
        if config.get("skills"):
            skilled.append({
                "room": room["id"],
                "skills": config["skills"],
            })

    report[sid] = skilled

# 2. Cache
Path("/cache").mkdir(parents=True, exist_ok=True)
Path("/cache/report.json").write_text(json.dumps(report))

# 3. Template
summary = tmpl_render(
    "Found {{ total }} skilled rooms across {{ servers }} servers",
    {
        "total": sum(len(v) for v in report.values()),
        "servers": len(report),
    },
)

# 4. Message bus
msg_send("reports", summary)

# 5. Return
{"summary": msg_recv("reports"), "report": report}
```
