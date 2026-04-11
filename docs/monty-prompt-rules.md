# Monty Sandbox — Prompt Rules for Code Generation

When an LLM generates Python code for the Monty sandbox, include these
rules in the system prompt or as an uploaded reference file.

## Core Rules

1. **All host functions return JSON strings.** Always `json.loads()` the result.
2. `import json` at the top of every program.
3. The last expression is the return value.
4. Return code in a `` ```monty``` `` fenced code block. No explanation outside it.

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
