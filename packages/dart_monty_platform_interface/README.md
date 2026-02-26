# dart_monty_platform_interface

Part of [dart_monty](https://github.com/runyaga/dart_monty) — pure Dart bindings for [Monty](https://github.com/pydantic/monty), a restricted, sandboxed Python interpreter built in Rust.

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

<img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/bob.png" alt="Bob" height="18"> This package is co-designed by human and AI — nearly all code is AI-generated.

**Pure Dart** platform interface for dart_monty. Defines the shared API contract (`MontyPlatform`) implemented by native and web backends, along with common types like `MontyResult`, `MontyException`, and `MontyResourceUsage`.

This package has no Flutter dependency and can be used in CLI tools, server-side Dart, or any Dart project.

- **Flutter apps** should import `dart_monty` instead — the federated plugin selects the correct backend automatically.
- **Pure Dart projects** (CLI, server) can depend on this package directly alongside `dart_monty_ffi` or `dart_monty_wasm`.

## Key Types

| Type | Description |
|------|-------------|
| `MontyPlatform` | Abstract contract for running Python code |
| `MontyResult` | Execution result with value, error, and resource usage |
| `MontyProgress` | Sealed type: `MontyPending` (awaiting external call) or `MontyComplete` |
| `MontyLimits` | Resource constraints (timeout, memory, stack depth) |
| `MontyException` | Python error with message, filename, line/column |
| `MontyResourceUsage` | Memory, time, and stack depth statistics |

## Usage

```dart
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

// Construct a result from JSON (as returned by native/web backends).
final result = MontyResult.fromJson({
  'value': 42,
  'usage': {
    'memory_bytes_used': 1024,
    'time_elapsed_ms': 5,
    'stack_depth_used': 2,
  },
});

print(result.value); // 42
print(result.usage.memoryBytesUsed); // 1024
```

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
