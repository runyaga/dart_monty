# Web Showcase — Host Function Reference

> LLM prompt: Use this document when generating Python code that runs inside the
> Monty interpreter in the browser. These are the available host functions —
> global functions callable from Python. There is no `import` needed.

## DOM Functions

All DOM functions use **opaque integer handles**. You get a handle from
`dom_create` or `dom_query`, then pass it to other functions. You never
touch raw DOM objects from Python.

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `dom_create` | `dom_create(tag)` | `int` (handle) | Create an HTML element |
| `dom_text` | `dom_text(handle, text)` | `None` | Set element's text content |
| `dom_get_text` | `dom_get_text(handle)` | `str` or `None` | Get element's text content |
| `dom_append` | `dom_append(parent_h, child_h)` | `None` | Append child to parent |
| `dom_query` | `dom_query(selector)` | `int` or `None` | querySelector — returns handle |
| `dom_style` | `dom_style(handle, prop, val)` | `None` | Set a CSS property |
| `dom_attr` | `dom_attr(handle, attr, val)` | `None` | Set an HTML attribute |
| `dom_html` | `dom_html(handle, html_str)` | `None` | Set innerHTML |
| `dom_remove` | `dom_remove(handle)` | `None` | Remove element from DOM |
| `dom_set_value` | `dom_set_value(handle, val)` | `None` | Set value on input/textarea/select |
| `dom_get_value` | `dom_get_value(handle)` | `str` or `None` | Get value from input/textarea/select |
| `dom_on_click` | `dom_on_click(handle)` | `"clicked"` | **Blocks** until element is clicked |
| `dom_await_click_any` | `dom_await_click_any([h1, h2, ...])` | `int` (handle) | **Blocks** until any listed element is clicked; returns which handle |

### Blocking click pattern

`dom_on_click` and `dom_await_click_any` **suspend Python execution** until
a click occurs. This is how you build interactive UIs — Python blocks, Dart
waits via a `Completer`, the click resolves it, Python resumes.

```python
# Single button
btn = dom_create("button")
dom_text(btn, "Click me")
dom_append(app, btn)
dom_on_click(btn)  # blocks here
log("Button was clicked!")

# Multiple buttons — event loop
for i in range(100):
    clicked = dom_await_click_any([save_btn, cancel_btn, delete_btn])
    if clicked == save_btn:
        # handle save
    elif clicked == cancel_btn:
        # handle cancel
```

## Network

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `fetch_text` | `fetch_text(url)` | `str` | HTTP GET, returns response body as text |
| `fetch_json` | `fetch_json(url)` | `dict`/`list` | HTTP GET, returns parsed JSON |

## Storage (localStorage)

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `storage_get` | `storage_get(key)` | `str` or `None` | Read from localStorage |
| `storage_set` | `storage_set(key, val)` | `None` | Write to localStorage |

## JSON Serialization

Since Monty does not have `import json`, these host functions provide
equivalent functionality. Named to match Python conventions.

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `json_dumps` | `json_dumps(obj)` | `str` | Like `json.dumps()` — serialize dict/list to JSON string |
| `json_loads` | `json_loads(s)` | `dict`/`list` | Like `json.loads()` — parse JSON string to Python object |

```python
data = {"name": "Bob", "level": 42}
s = json_dumps(data)          # '{"name":"Bob","level":42}'
storage_set("my_data", s)

# Later...
s = storage_get("my_data")
data = json_loads(s)           # {"name": "Bob", "level": 42}
```

## Interpreter State

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `interpreter_snapshot` | `interpreter_snapshot()` | `str` (base64) | Snapshot entire interpreter state |
| `interpreter_restore` | `interpreter_restore(b64)` | `"restored"` or error | Restore from base64 snapshot |

Snapshots capture **everything**: all variables, stack, heap. This is the
foundation for persistent object graphs — snapshot = commit, restore = abort.

## File I/O

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `download_file` | `download_file(filename, content)` | `None` | Trigger browser file download (content is base64) |
| `upload_file` | `upload_file()` | `str` or `None` | **Blocks** — opens file picker, returns base64 content |

## Utility

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `log` | `log(msg)` | `None` | Print to the output panel |
| `alert` | `alert(msg)` | `None` | Browser alert dialog |
| `now` | `now()` | `str` | Current time as ISO 8601 |

## Constraints

- **No `import`**: Monty is a subset of Python. No standard library modules.
- **No classes**: Use dicts and lists for data structures.
- **No async/await**: Host functions handle async internally — Python just calls them synchronously.
- **Handles are ints**: DOM elements are referenced by integer handles, never by object reference.
- **One click at a time**: `dom_on_click` / `dom_await_click_any` block execution. You cannot listen for multiple independent events simultaneously.
- **f-strings work**: `f"hello {name}"` is supported.
- **Functions work**: `def foo(x): return x + 1` is supported.
- **5-20ms per host call**: Each host function round-trip has overhead. Animations will be chunky/janky (which is fine).

## Complete Example: Persistent Key-Value Store

```python
app = dom_query("#sandbox")

# Load from localStorage
saved = storage_get("my_db")
if saved:
    root = json_loads(saved)
else:
    root = {}

# Add data
root["greeting"] = "hello"
root["count"] = 42

# Display
display = dom_create("pre")
dom_text(display, "root = " + json_dumps(root))
dom_append(app, display)

# Save button
btn = dom_create("button")
dom_text(btn, "COMMIT")
dom_append(app, btn)
dom_on_click(btn)

# Persist
storage_set("my_db", json_dumps(root))
log("Committed!")
```
