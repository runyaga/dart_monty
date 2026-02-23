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
import 'package:dart_monty/dart_monty.dart';

// Simple execution
final monty = MontyPlatform.instance;
final result = await monty.run('2 + 2');
print(result.value); // 4

// With resource limits
final limited = await monty.run(
  'fib(30)',
  limits: MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
);

// Iterative execution (external functions)
var progress = await monty.start(
  'fetch("https://example.com")',
  externalFunctions: ['fetch'],
);

if (progress is MontyPending) {
  print('Python called: ${progress.functionName}');
  progress = await monty.resume(myResult);
}

final complete = progress as MontyComplete;
print(complete.result.value);

// Error injection
progress = await monty.resumeWithError('network timeout');

// Async/futures — concurrent external calls via asyncio.gather
progress = await monty.start('''
import asyncio

async def main():
  a, b = await asyncio.gather(fetch("url1"), fetch("url2"))
  return a + b

await main()
''', externalFunctions: ['fetch']);

// Return Future for each pending call (native only)
while (progress is MontyPending) {
  progress = await monty.resumeAsFuture();
}

// Resolve all pending futures at once
if (progress is MontyResolveFutures) {
  final results = await Future.wait([fetchUrl("url1"), fetchUrl("url2")]);
  progress = await monty.resolveFutures({
    0: results[0],
    1: results[1],
  });
}

// Cleanup
await monty.dispose();
```

## Monty API Coverage (~35%)

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
| Async / futures (`asyncio.gather`, concurrent calls) | Planned | Native only — WASM upstream lacks `FutureSnapshot` API |
| Rich types (tuple, set, bytes, dataclass, namedtuple) | Planned | Currently collapsed to `List`/`Map` |
| REPL (stateful sessions, `feed()`, persistence) | Planned | `MontyRepl` multi-step sessions |
| OS calls (`os.getenv`, `os.environ`, `os.stat`) | Planned | `OsCall` progress variant |
| Print streaming (real-time callback) | Planned | Currently batch-only after execution |
| Advanced limits (allocations, GC interval, `runNoLimits`) | Planned | Extended `ResourceTracker` surface |
| Type checking (static analysis before execution) | Planned | ty / Red Knot integration |
| Progress serialization (suspend/resume across restarts) | Planned | `RunProgress::dump/load` |
| Platform expansion (Windows, iOS, Android) | Planned | macOS + Linux + Web today |

## Architecture

Federated plugin with six packages:

| Package | Type | Description |
|---------|------|-------------|
| `dart_monty` | Flutter plugin | App-facing API |
| `dart_monty_platform_interface` | **Pure Dart** | Abstract contract — no Flutter dependency |
| `dart_monty_ffi` | **Pure Dart** | Native FFI bindings (`dart:ffi` -> Rust) |
| `dart_monty_wasm` | **Pure Dart** | WASM bindings (`dart:js_interop` -> Web Worker) |
| `dart_monty_desktop` | Flutter plugin | Desktop platform (macOS/Linux, Isolate) |
| `dart_monty_web` | Flutter plugin | Web platform (browser, script injection) |

The three pure-Dart packages can be used without Flutter (e.g. in CLI tools
or server-side Dart).

### Native Path (desktop)

```text
Dart app -> MontyDesktop (Isolate)
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
