# Monty Sandbox Prompt Rules

Include these rules in prompts that request Python for a Monty runtime.
Function names and parameter shapes come from the host-function schemas that
the runtime registers.

## Core Rules

1. The last expression is the return value.
2. Call only registered host functions with schema-declared parameter names
   and value kinds.
3. Use `=` for assignment. Do not use `:=`.
4. Write top-level code. Do not define `main()` or use top-level `return`.
5. Use `print()` for progress output. The runtime captures it separately from
   the result.
6. Use dictionary indexing such as `item["name"]`, not attribute access.
7. Use f-strings or concatenation for formatted strings. Do not use `%`
   string formatting.
8. Write assignments separately. Do not use chained assignment.
9. Do not use `locals()`, `globals()`, `eval()`, or `exec()`.

## Monty Sandbox Limitations

Monty runs restricted Python rather than full CPython. Host functions expose
application capabilities. Register an `OsHandler` or `OSAccess` when Python
needs supported OS operations such as `pathlib.Path` access.

### Available standard library

The supported module set belongs to `dart_monty_core`. Consult its current
runtime source before promising a module to generated code.

### Error Handling

Avoid bare `except` and `except Exception: pass`. Catch a specific Python
exception when code can recover. Let other failures propagate to the Dart
caller.

```python
try:
    item = lookup(key="primary")
except KeyError:
    item = None

item
```

Generated code should rely only on failures promised by registered capability
schemas. [Host dispatch](https://github.com/runyaga/dart_monty/blob/main/lib/src/host/dispatch.dart)
defines error translation.

## Filesystem

`pathlib.Path` operations require an OS handler that accepts the matching
operation. Host functions remain the application boundary for network and
host-system access. Look in core's public `OSAccess` declaration for the
in-memory handler.
