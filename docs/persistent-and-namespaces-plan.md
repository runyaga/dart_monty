# Persistent Objects & Namespace Skills — Consolidated Plan

> Research synthesis: 3 Gemini iterations + grumpy engineer review + namespace
> research across soliplex server/flutter/dart_monty codebases.

## Executive Summary

We have 26 host functions bridging Python (Monty WASM) to browser APIs via
Dart. The core execution loop (start → pending → resume) works. The question
is how far we can push persistence and modularity with these primitives.

**Answer:** Surprisingly far. But only if we stay simple.

---

## Part 1: What Works Today (No New Dart Code)

### The Universal App Pattern

Every interactive demo follows the same loop:

```
render UI → dom_await_click_any → mutate state → save → re-render
```

This is proven in the showcase with forms, counters, and the persistent demo.

### Persistence via JSON + localStorage

```python
# Load
saved = storage_get("my_db")
root = json_loads(saved) if saved else {}

# Mutate
root["key"] = "value"

# Commit
storage_set("my_db", json_dumps(root))

# Abort
root = json_loads(storage_get("my_db"))
```

This IS the entire persistence layer. Everything else is ceremony.

### What We Can Build Today

| App | Complexity | Works? |
|-----|-----------|--------|
| Persistent key-value store | Trivial | Yes |
| Todo list (CRUD, persists across refresh) | Simple | Yes |
| Micro-journal with timestamps | Simple | Yes |
| Voting/poll system | Simple | Yes |
| Settings panel with toggles | Simple | Yes |
| Persistent state machine (FSM) | Medium | Yes |
| Transaction commit/abort | Medium | Yes |

All use only existing host functions. No new Dart code needed.

### Hard Walls

| Limitation | Why |
|-----------|-----|
| No lazy loading | Entire DB loaded as one JSON blob |
| No automatic dirty tracking | Monty has no classes, no `__setattr__` |
| No object identity (OIDs) | Dicts have no identity beyond their keys |
| DOM performance ceiling | ~10ms/call × 28 calls for 7 items = 280ms |
| localStorage quota (5MB) | No error handling, silent data loss |
| No multi-tab safety | Last-write-wins race condition |

---

## Part 2: The Pragmatic Persistence Layer

### What the Grumpy Engineer Said

> Kill the `dart_persistent` design. Implement two host functions:
> `save_state(key, obj)` and `load_state(key)`. That's the whole API.

### The 80/20 Plan

**Add 2 host functions** (replaces the verbose `json_dumps` + `storage_set` dance):

| Function | Signature | Dart Implementation |
|----------|-----------|-------------------|
| `save_state(key, obj)` | `save_state("my_db", root)` | `jsonEncode(args[1])` → `localStorage.setItem(args[0], ...)` with quota error handling |
| `load_state(key)` | `root = load_state("my_db")` | `localStorage.getItem(args[0])` → `jsonDecode(...)` or `{}` |

**Error handling built in:**
- `save_state` catches `QuotaExceededError` → returns `{"error": "QuotaExceeded"}`
- `load_state` returns `{}` for missing/corrupt keys (not None)
- Both handle circular references gracefully

**Python usage becomes trivial:**

```python
root = load_state("my_app")
root["visits"] = root.get("visits", 0) + 1
save_state("my_app", root)
# Done. Refresh page. Data persists.
```

### What NOT to Build (YAGNI)

- ~~PersistentMapping with dirty tracking~~ (Monty can't support it)
- ~~PersistentList~~ (same reason)
- ~~OID assignment~~ (no object identity in Monty)
- ~~Connection/Transaction classes~~ (over-engineered for dict persistence)
- ~~3 storage backends~~ (just localStorage for web, extend later if needed)
- ~~Snapshot-based persistence~~ (not portable, too coarse, not debuggable)

---

## Part 3: The Namespace Module System

### Existing Architecture in Soliplex

The soliplex ecosystem ALREADY has the building blocks:

**Server (Python):**
- `SKILL.md` files with YAML frontmatter
- `skills_ref.parser.read_properties()` parses them at runtime
- Skills discovered from `./skills/` directory
- Per-room skill selection

**Flutter (`soliplex_scripting`):**
- `HostFunctionWiring` groups functions by category via `addCategory()`
- `HostFunctionSchema` has `name`, `description`, `params` with types
- `HostFunctionRegistry.addCategory(name, functions)` for registration
- `HostFunctionRegistry.registerAllOnto(bridge)` for bulk registration
- Categories already exist: `df`, `chart`, `platform`, `stream`, `form`, `agent`

**dart_monty showcase:**
- 26 flat global host functions with prefix-as-namespace convention
- `showcase.prompt.md` documents the API for LLMs
- Dispatch via monolithic switch statement

### The `.prompt.md` Dual-Use Format

Each namespace module is a `.prompt.md` file with YAML frontmatter (machine)
and markdown body (human/LLM):

```yaml
---
namespace: dom
description: Browser DOM manipulation via opaque integer handles.
version: "1.0"
functions:
  - name: dom_create
    key: create
    signature: "dom_create(tag: str) -> int"
    returns: "int (handle)"
    description: "Create an HTML element by tag name"
    params:
      - name: tag
        type: string
        required: false
        default: "div"
    blocking: false
  - name: dom_on_click
    key: on_click
    signature: "dom_on_click(handle: int) -> str"
    returns: "str ('clicked')"
    description: "Block until element is clicked"
    params:
      - name: handle
        type: integer
        required: true
    blocking: true
---

# DOM Module

> LLM prompt: Use `dom_create`, `dom_text`, `dom_append`, etc. to
> manipulate the browser DOM. All elements are referenced by integer handles.

## Quick Example
...
```

### The Grumpy Engineer's Concern (and the Resolution)

**Concern:** "Parsing YAML at runtime couples docs to runtime. Docs drift.
Use a build step instead."

**Resolution:** Use `.prompt.md` as **source of truth**, but generate artifacts:

```
.prompt.md (source of truth)
    │
    ├──→ build step ──→ host_functions.g.dart (HostFunctionSchema objects)
    │                    (compile-time, no runtime YAML parsing)
    │
    └──→ bundled as string asset ──→ LLM system prompt context
                                     (runtime, for code generation)
```

The build step uses a simple Dart script that:
1. Reads `.prompt.md` files from a `namespaces/` directory
2. Parses YAML frontmatter
3. Generates a `.g.dart` file with `HostFunctionSchema` objects
4. Embeds the markdown body as a string constant for LLM prompts

**No runtime YAML parsing.** The `.prompt.md` is the single source of truth,
but the runtime consumes generated Dart code, not YAML.

### Room-Level Namespace Selection

```yaml
# room_config.yaml
id: "interactive-dashboard"
hostFunctionNamespaces:
  - dom
  - storage
  - json
  - fetch
```

Only selected namespaces are registered for that session. Python code can
only call functions from loaded namespaces. This is sandboxing by composition.

### Namespace Files

```
packages/soliplex_scripting/lib/src/
  host_functions/
    dom.prompt.md           # DOM manipulation (13 functions)
    storage.prompt.md       # localStorage (2 functions)
    json.prompt.md          # json_dumps/json_loads (2 functions)
    fetch.prompt.md         # fetch_text/fetch_json (2 functions)
    interpreter.prompt.md   # snapshot/restore (2 functions)
    file.prompt.md          # download/upload (2 functions)
    persistent.prompt.md    # save_state/load_state (2 functions)
    utility.prompt.md       # log/alert/now (3 functions)
```

### Python-Side Namespace Preamble (Optional)

If the user wants `dom["create"]` instead of `dom_create`, the build step
also generates a Python preamble:

```python
dom = {"create": dom_create, "text": dom_text, "append": dom_append, ...}
persistent = {"save": save_state, "load": load_state}
```

Prepended to user code before execution. **But the grumpy engineer warns:**
this is fragile — `dom = 1` in user code destroys the namespace. Flat globals
(`dom_create`) are safer. Make the preamble opt-in, not default.

---

## Part 4: LLM Integration

### How It Works

When an LLM needs to generate Python code for a Monty session:

1. System reads which namespaces are loaded for this room
2. For each namespace, grabs the embedded markdown body (from build artifact)
3. Assembles the LLM system prompt:

```
You are writing Python for a sandboxed Monty interpreter.
Available modules: dom, persistent, json.

## DOM Functions
[contents of dom.prompt.md markdown section]

## Persistent Functions
[contents of persistent.prompt.md markdown section]

## JSON Functions
[contents of json.prompt.md markdown section]

Write Python code to: [user's request]
```

4. The LLM generates code using ONLY the documented functions
5. No hallucinated imports, no unavailable APIs

### What This Unlocks

- **Per-room capability scoping** — LLM only sees functions available in that room
- **Self-documenting** — add a namespace = LLM automatically knows about it
- **Testable** — the prompt.md examples ARE the test cases
- **Versionable** — prompt.md files are in git, changes are reviewable

---

## Part 5: Implementation Plan (1 Week)

### Day 1-2: Persistence (ship immediately)

1. Add `save_state(key, obj)` host function with quota error handling
2. Add `load_state(key)` host function with graceful fallback
3. Update `showcase.prompt.md` with new functions
4. Add "Persistent Todo" demo using `save_state`/`load_state`
5. Test `while True` in Monty (critical for event loops)

### Day 3-4: Namespace Convention

6. Split `showcase.prompt.md` into per-namespace files (`dom.prompt.md`, etc.)
7. Write build script: parse YAML frontmatter → generate `host_functions.g.dart`
8. Verify generated schemas match existing `HostFunctionSchema` format
9. Update showcase to use generated dispatch table instead of manual switch

### Day 5: LLM Context Pipeline

10. Embed markdown bodies as string constants in generated code
11. Write helper: `getPromptContext(List<String> namespaces) → String`
12. Test with actual LLM: give it namespace prompts, verify code quality

### Stretch: Soliplex Integration

13. Add `hostFunctionNamespaces` to room config schema
14. Wire `HostFunctionWiring` to read namespace selection from config
15. Test per-room function scoping

---

## Part 6: Security Concerns

Flagged by grumpy engineer review:

| Concern | Severity | Mitigation |
|---------|----------|------------|
| `dom_html` = innerHTML = XSS | High | Sanitize or replace with safe builder |
| localStorage quota exhaustion | Medium | `save_state` returns structured error |
| Multi-tab race condition | Medium | Document as single-tab only (v1) |
| Namespace clobbering (`dom = 1`) | Low | Use flat globals, preamble is opt-in |
| Circular reference in `json_dumps` | Low | Catch in Dart, return error |

---

## Part 7: What We Got Right

From the grumpy engineer:

> The use of opaque integer handles for DOM elements is exactly right.
> The basic execution loop (start → pending → resume) is a proven, solid
> pattern. The showcase itself is impressive — you've proven the core tech
> is viable.

The strongest foundation:
- **Handle-based DOM** — correct abstraction for bridging sandboxed → browser
- **Host function dispatch loop** — battle-tested pattern
- **26 working host functions** — enough to build real apps
- **The showcase** — people see it and immediately understand
- **`.prompt.md` convention** — single source of truth for both LLMs and humans

---

## Appendix: Key File Locations

### dart_monty-cli
- `example/web-showcase/bin/showcase.dart` — 26 host functions + dispatch
- `example/web-showcase/bin/showcase.prompt.md` — LLM API reference
- `example/web-showcase/web/showcase.html` — UI with collapsible API panel
- `docs/dart-persistent-design.md` — original design (superseded by this doc)
- `docs/persistent-and-namespaces-plan.md` — THIS DOCUMENT

### soliplex-flutter
- `packages/soliplex_scripting/lib/src/host_function_wiring.dart` — category-based registration
- `packages/soliplex_interpreter_monty/lib/src/bridge/host_function_schema.dart` — schema types
- `packages/soliplex_interpreter_monty/lib/src/bridge/host_function.dart` — HostFunction type
- `packages/soliplex_interpreter_monty/lib/src/bridge/host_function_registry.dart` — registry

### soliplex (server)
- `src/soliplex/config.py` — SkillConfig, skill discovery via SKILL.md
- `example/rooms/` — room configurations
