# Handling Results and Errors

When using `dart_monty_mcp` programmatically, all execution methods return
a `Future<CallToolResult>` from the `mcp_dart` package. This guide explains
the structure and how to interpret both success and error results.

> **Runnable examples:** See
> [`example/programmatic.dart`](../example/programmatic.dart). Result
> handling patterns are tested in CI via `test/src/examples_test.dart`.

## The CallToolResult object

A `CallToolResult` has two key properties:

- `isError` (`bool`): `false` for success, `true` if a Python or host
  function error occurred.
- `content` (`List<Content>`): Always contains a single `TextContent`
  object for this package.

Extract the text output:

```dart
final result = await session.execute('2 + 2');
final text = (result.content.first as TextContent).text;
// text == '4'
```

## Output format

The text inside `TextContent` combines two sources:

1. **Captured `print()` output** -- any text sent to `print()` in Python
2. **Expression result** -- the value of the last expression

These are concatenated, separated by a newline:

```python
# Python code:
print("Calculating...")
2 + 2
```

```text
Calculating...
4
```

If there is no `print()` output and no trailing expression (e.g. just
`x = 5`), the output is `(no output)`.

## Error results

When Python raises an exception or a host function handler throws:

```dart
final result = await session.execute('1 / 0');
if (result.isError) {
  final message = (result.content.first as TextContent).text;
  // message contains the Python exception message
}
```

Error results include any `print()` output that occurred before the error,
followed by the error message.

## Adapter functions

The public API includes two adapter functions that convert raw interpreter
events into `CallToolResult`. You typically don't call these directly, but
understanding them helps when debugging.

### `montyResultToCallToolResult`

Used by persistent sessions (`McpMontySession`). Takes a `MontyResult`
from a completed session execution:

- **Success**: combines `result.printOutput` and `result.value`
- **Error**: combines `result.printOutput` and `result.error.message`,
  sets `isError: true`

### `bridgeEventsToResult`

Used by stateless execution (`executeStateless`). Consumes a
`Stream<BridgeEvent>` from the bridge:

- Buffers `BridgeTextContent` events to capture `print()` output
- `BridgeRunFinished` → success result
- `BridgeRunError` → error result with `isError: true`

Both adapters produce a consistent result format regardless of execution
mode (stateless vs. session).
