# dart_monty

<p align="center">
  <img src="docs/dart_monty.jpg" alt="dart_monty" width="400">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

[Monty](https://github.com/pydantic/monty) is a restricted, sandboxed Python interpreter built in Rust by the [Pydantic](https://github.com/pydantic) team. It runs a safe subset of Python designed for embedding.

<img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/bob.png" alt="Bob" height="18"> This package is co-designed by human and AI — nearly all code is AI-generated.

**dart_monty** provides pure Dart bindings for the Monty interpreter, bringing sandboxed Python execution to Dart and Flutter apps — on desktop, web, and mobile — with resource limits, iterative execution, and snapshot/restore support.

> **Fork notice:** dart_monty currently builds against [`runyaga/monty`](https://github.com/runyaga/monty) (branch `runyaga/main`), a fork of [`pydantic/monty`](https://github.com/pydantic/monty). The fork carries patches required for embedding that are not yet upstream. We intend to upstream all changes and return to `pydantic/monty` once accepted.
>
> | Patch | Fork PR | Upstream PR | Status | Why needed |
> |-------|---------|-------------|--------|------------|
> | Fix partial future resolution panics in mixed `asyncio.gather()` | — | [pydantic/monty#251](https://github.com/pydantic/monty/pull/251) | Submitted, awaiting review | Two panics in `async_exec.rs` when a gather mixes coroutine tasks with direct external calls — blocks any async host function use |
> | CancellableTracker (preemptive script cancellation) | [runyaga/monty#3](https://github.com/runyaga/monty/pull/3) | Not yet submitted | Merged in fork | Cooperative cancel via `Arc<AtomicBool>` checked in bytecode loop — required for `dispose()` to not hang on stuck FFI calls |
> | `cpu: wasm32` restriction in `monty-wasm32-wasi` npm package | — | [runyaga/monty#4](https://github.com/runyaga/monty/issues/4) | Open issue | npm refuses install on non-wasm hosts, blocking CI and local dev |

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
dart pub add dart_monty
```

## Usage

```dart
import 'package:dart_monty/dart_monty.dart';

final monty = Monty();

// Simple execution
final result = await monty.run('2 + 2');
print(result.value); // 4

// With resource limits
final limited = await monty.run(
  'fib(30)',
  limits: const MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
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

### Error Handling

dart_monty uses a sealed `MontyError` hierarchy for structured error handling:

```dart
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

try {
  final result = await monty.run('1 / 0');
} on MontyError catch (e) {
  switch (e) {
    case MontyScriptError(:final exception):
      print('Python error: ${exception.message}');
      print('Type: ${exception.excType}');
      for (final frame in exception.traceback) {
        print('  ${frame.filename}:${frame.lineNumber} in ${frame.name}');
      }
    case MontyCancelledError():
      print('Execution was cancelled');
    case MontyResourceError(:final exception):
      print('Resource limit exceeded: ${exception.message}');
    case MontyPanicError(:final message):
      print('Interpreter panic: $message');
    case MontyCrashError(:final message):
      print('Interpreter crash: $message');
    case MontyDisposedError():
      print('Interpreter was disposed');
  }
}
```

### Cancellation

Cancel a running interpreter from any isolate using `MontyCancelToken`:

```dart
final token = MontyCancelToken(handleId);
token.cancel(); // sets atomic flag in bytecode loop
```

### Stateful Sessions

`MontySession` persists Python globals across multiple `run()` calls using
snapshot/restore under the hood:

```dart
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

final session = MontySession(platform: Monty());

// Globals persist across run() calls via snapshot/restore
await session.run('x = 42');
await session.run('y = x * 2');
final result = await session.run('x + y');
print(result.value); // 126

// Session also supports start/resume (same dispatch pattern)
await session.clearState();
await session.dispose();
```

## Monty API Coverage (~75%)

dart_monty wraps the [Monty Rust API](https://github.com/runyaga/monty) (fork of [pydantic/monty](https://github.com/pydantic/monty)).
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
| **Cancellation** (cooperative abort via atomic flag) | Covered | `MontyCancelToken`, `cancel()`, `terminate()` with zombie tracking |
| **Error hierarchy** (sealed `MontyError` with 6 subtypes) | Covered | Script, Cancel, Panic, Crash, Disposed, Resource |
| **Multi-session** (WASM Worker pool) | Covered | `createSession`/`disposeSession`, 16 MB per session |
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

dart_monty selects the native or web backend at compile time via conditional
imports — no Flutter required. Four pure-Dart packages:

| Package | Description |
|---------|-------------|
| `dart_monty` | App-facing API — `Monty()` convenience class with compile-time backend selection |
| `dart_monty_platform_interface` | Abstract contract (`MontyPlatform`), shared types, SPI for backend authors |
| `dart_monty_ffi` | Native FFI bindings (`dart:ffi` -> Rust shared library) |
| `dart_monty_wasm` | WASM bindings (`dart:js_interop` -> Web Worker) |

All packages are pure Dart and work in CLI tools, server-side Dart, and
Flutter apps alike.

### Native Path (desktop)

```text
Dart app -> Monty() -> MontyFfi (dart:ffi)
  -> libdart_monty_native.{dylib,so}
    -> Monty Rust interpreter
```

### Web Path (browser)

```text
Dart app (compiled to JS) -> Monty() -> MontyWasm (dart:js_interop)
  -> Web Worker -> @pydantic/monty WASM
```

The Web Worker architecture bypasses Chrome's 8 MB synchronous WASM
compilation limit.

### Web Setup

The web backend requires COOP/COEP HTTP headers for SharedArrayBuffer
support:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, gate scripts,
and CI details.

## License

MIT License. See [LICENSE](LICENSE).
