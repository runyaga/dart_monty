# dart_monty

<p align="center">
  <img src="docs/dart_monty.jpg" alt="dart_monty" width="400">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

[Monty](https://github.com/pydantic/monty) is a restricted, sandboxed Python interpreter built in Rust by the [Pydantic](https://github.com/pydantic) team. It runs a safe subset of Python designed for embedding.

**dart_monty** provides pure Dart bindings for the Monty interpreter, bringing sandboxed Python execution to Dart and Flutter apps — on desktop, web, and mobile — with resource limits, iterative execution, and snapshot/restore support.

## Platform Support

| Platform | Status |
|----------|--------|
| macOS | Supported |
| Linux | Supported |
| Web (browser) | Supported |
| Windows | Planned |
| iOS | Planned |
| Android | Planned |

## Installation

```bash
flutter pub add dart_monty
```

## Usage

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dart_monty/dart_monty.dart';

final monty = MontyPlatform.instance;

// Simple execution
final result = await monty.run('2 + 2');
print(result.value); // 4

// With resource limits
final limited = await monty.run(
  'fib(30)',
  limits: MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
);
```

### External Functions

When Python calls a function listed in `externalFunctions`, execution
pauses and Dart handles the call. The function name in Python maps 1:1
to the name you provide — when Python calls `fetch(...)`, Dart receives
a `MontyPending` with `functionName == 'fetch'` and the arguments Python
passed.

```dart
// Python calls fetch() → execution pauses → Dart handles it → resumes
var progress = await monty.start(
  'fetch("https://api.example.com/users")',
  externalFunctions: ['fetch'],
);

// Dispatch loop: match functionName to your Dart implementation
while (progress is MontyPending) {
  final pending = progress as MontyPending;
  final name = pending.functionName; // 'fetch'
  final args = pending.arguments;    // ['https://api.example.com/users']

  switch (name) {
    case 'fetch':
      final url = args.first as String;
      final response = await http.get(Uri.parse(url));
      progress = await monty.resume(jsonDecode(response.body));
    default:
      progress = await monty.resumeWithError(
        'Unknown function: $name',
      );
  }
}

final complete = progress as MontyComplete;
print(complete.result.value);

await monty.dispose();
```

### Stateful Sessions

`MontySession` persists Python globals across multiple `run()` calls using
snapshot/restore under the hood:

```dart
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

final session = MontySession(MontyPlatform.instance);

// Globals persist across run() calls via snapshot/restore
await session.run('x = 42');
await session.run('y = x * 2');
final result = await session.run('x + y');
print(result.value); // 126

// Session also supports start/resume (same dispatch pattern)
await session.clearState();
await session.dispose();
```

## Monty API Coverage (~68%)

dart_monty wraps the upstream [Monty Rust API](https://github.com/pydantic/monty).
The table below shows current coverage and what's planned.

| API Area | Status | Notes |
|----------|--------|-------|
| **Core execution** (`run`, `start`, `resume`, `dispose`) | Covered | Full iterative execution loop |
| **External functions** (host-provided callables) | Covered | `start()` / `resume()` / `resumeWithError()` |
| **Resource limits** (time, memory, recursion depth) | Covered | `MontyLimits` on `run()` and `start()` |
| **Print capture** (`print()` output collection) | Covered | `MontyResult.printOutput` |
| **Snapshot / restore** (`MontyRun::dump/load`) | Covered | Compile-once, run-many pattern |
| **Exception model** (excType, traceback, stack frames) | Covered | Full `MontyException` with `StackFrame` list |
| **Call metadata** (kwargs, callId, methodCall, scriptName) | Covered | Structured external call context |
| Async / futures (`asyncio.gather`, concurrent calls) | Covered | Native only — WASM upstream lacks `FutureSnapshot` API |
| Rich types (tuple, set, bytes, dataclass, namedtuple) | Planned | Currently collapsed to `List`/`Map` |
| REPL (stateful sessions, `feed()`, persistence) | Planned | `MontyRepl` multi-step sessions |
| OS calls (`os.getenv`, `os.environ`, `os.stat`) | Planned | `OsCall` progress variant |
| Print streaming (real-time callback) | Planned | Currently batch-only after execution |
| Advanced limits (allocations, GC interval, `runNoLimits`) | Planned | Extended `ResourceTracker` surface |
| Type checking (static analysis before execution) | Planned | ty / Red Knot integration |
| Progress serialization (suspend/resume across restarts) | Planned | `RunProgress::dump/load` |
| Platform expansion (Windows, iOS, Android) | Planned | macOS + Linux + Web today |

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed architecture
documentation including state machine contracts, memory management, error
handling, and cross-backend parity guarantees.

Federated plugin with six packages:

| Package | Type | Description |
|---------|------|-------------|
| `dart_monty` | Flutter plugin | App-facing API |
| `dart_monty_platform_interface` | **Pure Dart** | Abstract contract — no Flutter dependency |
| `dart_monty_ffi` | **Pure Dart** | Native FFI bindings (`dart:ffi` -> Rust) |
| `dart_monty_wasm` | **Pure Dart** | WASM bindings (`dart:js_interop` -> Web Worker) |
| `dart_monty_native` | Flutter plugin | Native platform (desktop + mobile, Isolate) |
| `dart_monty_web` | Flutter plugin | Web platform (browser, script injection) |

The three pure-Dart packages can be used without Flutter (e.g. in CLI tools
or server-side Dart).

### Native Path (desktop)

```text
Dart app -> MontyNative (Isolate)
  -> MontyFfi (dart:ffi)
    -> libdart_monty_native.{dylib,so}
      -> Monty Rust interpreter
```

### Web Path (browser)

```text
Dart app (compiled to JS) -> DartMontyWeb
  -> MontyWasm (dart:js_interop)
    -> Web Worker -> @pydantic/monty WASM
```

The Web Worker architecture bypasses Chrome's 8 MB synchronous WASM
compilation limit.

### Web Setup

The web backend requires COOP/COEP HTTP headers for SharedArrayBuffer
support:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, gate scripts,
and CI details.

## License

MIT License. See [LICENSE](LICENSE).
