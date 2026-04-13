# API Reference

`dart_monty` provides three levels of API, depending on your needs for state management and plugin support.

## 1. AgentSession (Recommended)

`AgentSession` is the high-level facade for building stateful agents. It handles tool registration, OS virtualization, and variable persistence automatically.

### Basic Execution

```dart
final session = AgentSession();
final result = await session.execute('x = 42');
print(result.value); // 42
```

### Reactive State

`AgentSession` implements `MontyStateMixin` and provides reactive signals via [signals_core](https://pub.dev/packages/signals_core).

```dart
// React to variable changes
effect(() {
  final variables = session.sessionStateSignal.value;
  print("Active variables: ${variables.keys}");
});

// React to lifecycle changes
effect(() {
  if (session.stateSignal.value == MontyLifecycleState.disposed) {
    print("Session closed");
  }
});
```

### Using Plugins

```dart
final session = AgentSession(
  plugins: [
    MessageBusPlugin(),
    SandboxPlugin(platformFactory: () async => MontyFfi()),
  ],
);
```

---

## 2. ReplSession (Native Only)

For workloads requiring high-performance persistence of complex objects (functions, classes, closures), `ReplSession` uses a native Rust heap that persists across calls.

```dart
final session = ReplSession();
await session.run('def greet(name): return f"Hello {name}"');
final result = await session.run('greet("Monty")'); 
print(result.value); // "Hello Monty"
```

---

## 3. Monty (Low-Level)

The `Monty` class provides raw access to the interpreter. Use this for one-shot scripts where no state or plugin system is required.

```dart
final result = await Monty.run('2 + 2');
print(result.value); // 4
```

### Manual Iteration

If you aren't using `AgentSession`, you must handle external function calls manually:

```dart
final monty = Monty();
var progress = await monty.platform.start(
  'html = fetch("https://example.com")',
  externalFunctions: ['fetch'],
);

if (progress is MontyPending) {
  // Manual dispatch...
  progress = await monty.platform.resume(htmlData);
}
```

---

## Shared Types

| Type | Description |
|------|-------------|
| `MontyResult` | The output of an execution, including `.value` and `.usage`. |
| `MontyValue` | A boxed Python value (e.g., `MontyInt`, `MontyString`, `MontyMap`). |
| `MontyLimits` | Resource constraints (`timeoutMs`, `memoryBytes`, `stackDepth`). |
| `MontyException` | Thrown when Python code fails, includes `.traceback`. |
| `MontyLifecycleState` | `idle`, `active`, or `disposed`. |

### MontyResult Fields

- `value`: The `MontyValue` returned by the script.
- `error`: Non-null if execution failed (and wasn't caught in Python).
- `usage`: A `MontyResourceUsage` object tracking memory and time.
- `printOutput`: All text captured from `print()` calls during execution.
