# dart_monty_platform_interface

Platform interface for dart_monty. Defines the shared API contract (`MontyPlatform`) implemented by native and web backends, along with common types like `MontyResult`, `MontyException`, and `MontyResourceUsage`.

This package is not intended for direct use. Import `dart_monty` instead.

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
