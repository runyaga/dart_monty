# Live Shape Negotiation: Research Document

## Problem

The soliplex ecosystem has a shape synchronization problem. The
Python FastAPI backend defines API shapes as Pydantic models. The
Flutter frontend consumes them via 44 hand-written fromJson/toJson
mappers with manual snake\_case conversion. No codegen, no shared
schema, no compile-time safety across the boundary. Every backend
model change requires a manual Dart update.

## Proposal

Use the Monty sandboxed Python interpreter (already embedded in
Dart via dart\_monty) to execute Python schema code served by the
backend. The Python code IS the contract — both sides can execute
it, so they're always in sync. No build step, no codegen, no
schema drift.

## Architecture

```text
Backend (Python/FastAPI/Pydantic)
  |
  | GET /api/v1/schema/monty
  | (serves auto-generated Monty-compatible Python code)
  |
  v
Flutter App
  |
  | Fetches schema code at startup
  | Executes in Monty sandbox
  | Gets back: type definitions, validators, transformers
  |
  v
SchemaRegistry (Dart)
  |
  | Provides:
  |   - Type validation for API responses
  |   - Key transformation (snake_case <-> camelCase)
  |   - Tool definitions for LLM agent loop
  |   - Form field generation for dynamic UI
  |
  v
Replaces 44 hand-written mappers
```

## Monty Capability Constraints

Monty is a sandboxed Python interpreter. It CANNOT do:

- Classes (no `class` keyword)
- Imports (no `import math`, no `import pydantic`)
- Decorators
- Generators/yield
- Context managers (with)

Monty CAN do:
- Functions (def, \*args, \*\*kwargs, closures, lambda)
- Dicts, lists, tuples, all primitives
- Control flow (if/for/while/try-except)
- Dict/list comprehensions
- String methods, f-strings
- Built-ins (len, range, isinstance, type, sorted, etc.)
- External function calls (pause/resume bridge to Dart)

Key implication: schemas must be expressed as dicts and
functions, not as classes.

## What the Generated Schema Code Looks Like

```python
# AUTO-GENERATED from soliplex.models (Pydantic)
# Version: 3, Hash: sha256:abc123

def _to_camel(snake):
    parts = snake.split("_")
    return parts[0] + "".join(
        p[0].upper() + p[1:] for p in parts[1:] if p
    )

def _make_key_map(fields):
    result = {}
    for f in fields:
        camel = _to_camel(f)
        if camel != f:
            result[f] = camel
            result[camel] = f
    return result

schemas = {}

schemas["Room"] = {
    "name": "Room",
    "version": 3,
    "fields": {
        "id": {"type": "str", "required": True},
        "name": {"type": "str", "required": True},
        "description": {"type": "str", "required": True},
        "welcome_message": {
            "type": "str", "required": True,
        },
        "suggestions": {
            "type": "list",
            "item_type": "str",
            "required": True,
        },
        "enable_attachments": {
            "type": "bool", "required": True,
        },
        "allow_mcp": {
            "type": "bool", "required": True,
        },
    },
    "key_map": _make_key_map([
        "welcome_message",
        "enable_attachments",
        "allow_mcp",
    ]),
}

schemas["ThreadInfo"] = {
    "name": "ThreadInfo",
    "version": 2,
    "fields": {
        "thread_id": {
            "type": "str", "required": True,
        },
        "room_id": {
            "type": "str", "required": True,
        },
        "created": {
            "type": "str",
            "required": True,
            "format": "datetime",
        },
        "metadata": {
            "type": "dict",
            "required": False,
            "default": {},
        },
    },
    "key_map": _make_key_map(["thread_id", "room_id"]),
}

# Validation
def validate(schema_name, data):
    schema = schemas[schema_name]
    errors = []
    for field_name, field_def in schema["fields"].items():
        if field_def["required"] and field_name not in data:
            errors.append(
                f"Missing required field: {field_name}"
            )
            continue
        if field_name in data:
            value = data[field_name]
            expected = field_def["type"]
            if expected == "str" and \
                    not isinstance(value, str):
                errors.append(
                    f"{field_name}: expected str, "
                    f"got {type(value).__name__}"
                )
            elif expected == "bool" and \
                    not isinstance(value, bool):
                errors.append(
                    f"{field_name}: expected bool, "
                    f"got {type(value).__name__}"
                )
            elif expected == "list" and \
                    not isinstance(value, list):
                errors.append(
                    f"{field_name}: expected list, "
                    f"got {type(value).__name__}"
                )
    if errors:
        return {"valid": False, "errors": errors}
    return {"valid": True, "errors": []}

# Key transformation
def transform_keys(data, key_map):
    result = {}
    for k, v in data.items():
        new_key = key_map.get(k, k)
        if isinstance(v, dict):
            result[new_key] = transform_keys(
                v, key_map
            )
        elif isinstance(v, list):
            result[new_key] = [
                transform_keys(item, key_map)
                if isinstance(item, dict) else item
                for item in v
            ]
        else:
            result[new_key] = v
    return result

# Return everything
{"schemas": schemas, "version": 3}
```

## Frontend Execution Flow

```dart
// At startup
final schemaCode = await api.fetchSchemaCode();
final result = await montyPlatform.run(
  schemaCode,
  limits: MontyLimits(...),
);
final registry = SchemaRegistry.fromMontyResult(
  result.value,
);

// Replace hand-written mappers
Room roomFromJson(Map<String, dynamic> json) {
  final transformed = registry.transformToDart(
    'Room', json,
  );
  return Room(
    id: transformed['id'] as String,
    name: transformed['name'] as String,
    // ...
  );
}
```

## Backend: Generating the Code

A new Python module `schema_codegen.py` introspects Pydantic
models:

```python
def pydantic_to_monty_schema(model_cls):
    fields = {}
    for name, field_info in model_cls.model_fields.items():
        fields[name] = {
            "type": python_type_to_str(
                field_info.annotation,
            ),
            "required": field_info.is_required(),
        }
        if field_info.default is not None:
            fields[name]["default"] = field_info.default
    return fields
```

Served via: `GET /api/v1/schema/monty` with ETag caching.

## What This Enables Beyond Static Schemas

1. **Executable transformers**: `transform_keys()` converts
   snake\_case to camelCase — JSON Schema can't do this
2. **Cross-field validation**: logic-based validation, not just
   declarations
3. **Version migration**: compute new fields from old data —
   JSON Schema has no migration concept
4. **Unified tool specs**: Same schema code generates both API
   validators and LLM tool definitions
5. **Runtime sync**: No build step — schema changes are picked
   up at next app startup

## Connection to Monty Bridge

The host function bridge (separate design) registers Dart
functions callable from Python. The live schema negotiation
uses the same Monty runtime. They converge:

- Schema code defines tool specifications — fed to LLM as
  tool\_use parameters
- Bridge executes LLM-generated Python — pauses at external
  function calls
- Schemas validate tool call arguments and return values
- One Monty runtime, one schema source, two consumers
  (API client + LLM agent)

## Security

Monty is sandboxed — no filesystem, no network, no system
access. Even if the schema endpoint is compromised, the attacker
can only:

- Return wrong schemas (data corruption, not code execution)
- Return infinite loops (mitigated by MontyLimits timeout)
- Return memory bombs (mitigated by MontyLimits memory cap)

Additional: sign schema code with HMAC, pin expected versions.

## Performance Estimates

- Schema code fetch: 50-200ms (network, cached after first)
- Monty execution (native FFI): 50-200ms for ~2000 lines
- Monty execution (WASM web): 200-500ms
- Per-response validation: 5-15ms (native), debug builds only

## Phased Approach

### Phase 1: Prove concept

Hand-write Monty Python for one model (Room). Execute in Dart
test. Validate a real API response. Measure performance.

### Phase 2: Auto-generate

Build schema\_codegen.py in backend. Introspect Pydantic models.
Serve via endpoint.

### Phase 3: Replace mappers

Build SchemaRegistry Dart class. Replace hand-written fromJson
for 6 key types.

### Phase 4: Unify with bridge

Tool definitions from schema code. LLM agent uses same schemas.
Dynamic UI from field metadata.

## Open Questions

1. Schema size budget — how large before Monty execution
   becomes slow?
2. REPL API (M12) — would allow defining functions once and
   calling repeatedly without re-executing
3. Backward compatibility — what if frontend caches schema v3
   but backend rolled back to v2?
4. Multiple backends — app connects to different soliplex
   instances with different schema versions
5. Is this over-engineered vs. just running quicktype on the
   OpenAPI spec?
