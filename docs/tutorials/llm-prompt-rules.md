# Monty Sandbox Prompt Rules

Include these rules in prompts that request Python for a Monty runtime.
Function names and parameter shapes come from the host-function schemas that
the runtime registers.

## Core Rules

1. The last expression is the return value.
2. Call only registered host functions with the parameter names and value
   kinds their schemas declare.
3. Use `help()` to list registered functions and `help("function_name")` to
   inspect one function.
4. Use `=` for assignment. Do not use `:=`.
5. Write top-level code. Do not define `main()` or use top-level `return`.
6. Use `print()` for progress output. The runtime captures it separately from
   the result.
7. Use dictionary indexing such as `item["name"]`, not attribute access.
8. Use f-strings or concatenation for formatted strings. Do not use `%`
   string formatting.
9. Write assignments separately. Do not use chained assignment.
10. Do not use `locals()`, `globals()`, `eval()`, or `exec()`.

```monty
print("Calling the registered search function")
result = search(query="Dart")
result
```

## Monty Sandbox Limitations

Monty runs restricted Python rather than full CPython. Host functions expose
application capabilities. Register an `OsHandler` or `OSAccess` when Python
needs supported OS operations such as `pathlib.Path` access.

### Available standard library

- `json`
- `math`
- `re`
- `pathlib`
- `datetime`
- `collections`

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

Validation and ordinary handler failures raise Python `RuntimeError`. A
handler can raise a selected Python exception such as `PermissionError` by
throwing `ExternalException` in Dart. An unknown host function raises
`NameError`.

## Host Function Patterns

Host functions use their declared Python arguments and return Monty values.
Use the function schema rather than assuming JSON-string results.

```monty
record = get_record(id=7)
print(record)
record
```

## Filesystem

`pathlib.Path` operations require an OS handler that accepts the matching
operation. `OSAccess().call` provides an in-memory `Path.` handler. Host
functions remain the application boundary for network and host-system access.
