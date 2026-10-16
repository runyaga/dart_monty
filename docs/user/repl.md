# Stateful Interactive Execution

Import `package:dart_monty/dart_monty.dart` for the runtime and session APIs.
A session retains Python globals across feeds. Close sessions and dispose
runtimes when finished.

## Sessions and type checking

```dart
await Monty.withPool((pool) async {
  final session = await pool.checkout(typeCheck: true);
  try {
    await session.feedRun('x: int = 42');
    final result = await session.feedRun('x + 1');
    print(result.dartValue); // 43
  } finally {
    await session.close();
  }
});
```

Each feed is checked before it executes. Import `MontyTypingError` directly
from core's public library to catch type-checking failures. Checkout also
accepts `typeCheckStubs` for host-provided function and input declarations.

## Runtime with extensions

```dart
final runtime = await MontyRuntime.start(
  extensions: [EventLoopExtension()],
);
try {
  await runtime.execute('x = 42').result;
  final handle = runtime.execute('x + 1');
  final events = handle.events.toList();
  print((await handle.result).dartValue); // 43
  print(await events);
} finally {
  await runtime.dispose();
}
```

`MontyRuntime` dispatches registered host functions and exposes run/call events.
For low-level snapshot handling, import the snapshot types directly from
`package:dart_monty_core/dart_monty_core.dart`.

## Tool discovery

The built-in `help()` host function reflects the current registered tools.
`help('el_recv')` returns the event-loop receive schema when that extension
is attached. Registrations are visible without restarting the runtime.
