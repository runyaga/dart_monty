# dart_monty

<p align="center">
  <img src="docs/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

[Monty](https://github.com/pydantic/monty) is a restricted, sandboxed Python interpreter built in Rust by the [Pydantic](https://github.com/pydantic) team. It runs a safe subset of Python designed for embedding.

**dart_monty** provides pure Dart bindings for the Monty interpreter, bringing sandboxed Python execution to Dart and Flutter apps — on desktop, web, and mobile — with resource limits, iterative execution, and snapshot/restore support.

> **Fork notice:** dart_monty currently builds against [`runyaga/monty`](https://github.com/runyaga/monty) (branch `runyaga/main`), a fork of [`pydantic/monty`](https://github.com/pydantic/monty). The fork carries patches required for embedding that are not yet upstream. We intend to upstream all changes and return to `pydantic/monty` once accepted.
>
> | Patch | Fork PR | Upstream PR | Status | Why needed |
> |-------|---------|-------------|--------|------------|
> | Fix partial future resolution panics in mixed `asyncio.gather()` | — | [pydantic/monty#251](https://github.com/pydantic/monty/pull/251) | Submitted, awaiting review | Two panics in `async_exec.rs` when a gather mixes coroutine tasks with direct external calls — blocks any async host function use |
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

## Quick Start

**1. Add the dependency**

```bash
dart pub add dart_monty
```

**2. One-shot evaluation**

```dart
import 'package:dart_monty/dart_monty.dart';

void main() async {
  // Monty.exec() creates an interpreter, runs the code, and disposes — one call.
  final result = await Monty.exec('2 + 2');
  print(result.value); // 4
}
```

**3. Reusable interpreter**

```dart
import 'package:dart_monty/dart_monty.dart';

void main() async {
  // Monty() is a facade — it selects FFI or WASM at compile time.
  // It does NOT implement MontyPlatform; use .platform for capability checks.
  final monty = Monty();
  final result = await monty.run('2 + 2');
  print(result.value); // 4
  await monty.dispose();
}
```

**4. Run it**

```bash
$ dart run
4
```

No Flutter. No bindings. No registration. It just works.

### OS Call Support (filesystem, env, datetime)

Pass an `os` provider to enable Python `pathlib`, `os`, and `datetime` access.
Without a provider, OS calls resume with a `PermissionError`.

```dart
import 'package:dart_monty/dart_monty.dart';

void main() async {
  // defaultSandboxOs() wires up filesystem, env, and datetime
  // access with platform-appropriate defaults (native FS on desktop,
  // in-memory FS on web).
  final monty = Monty(os: defaultSandboxOs());

  final result = await monty.run('''
from pathlib import Path
Path("/tmp/hello.txt").write_text("hello")
Path("/tmp/hello.txt").read_text()
''');
  print(result.value); // hello

  await monty.dispose();
}
```

For custom filesystem backends, use `FsProvider` with any
`package:file` `FileSystem` implementation. See [docs/oscall-vfs.md](docs/oscall-vfs.md)
for the full provider hierarchy.

### Web Quick Start

The same Dart code runs in the browser — `Monty()` selects the WASM backend
at compile time. You need three asset files and COOP/COEP headers.

**1. Build the WASM binary and JS bridge**

```bash
# Build the Rust WASM binary
cd native && cargo build --release --target wasm32-wasip1

# Build the JS bridge and worker
cd spike/web_test && npm install --force && npm run bundle
```

**2. Copy assets into your web directory**

```bash
cp spike/web_test/web/monty_bundle.js web/dart_monty_bridge.js
cp spike/web_test/web/monty_worker.js web/
cp native/target/wasm32-wasip1/release/dart_monty_native.wasm web/
```

**3. Write your Dart code** (same API as native)

```dart
import 'package:dart_monty/dart_monty.dart';

void main() async {
  final result = await Monty.exec('2 + 2');
  print(result.value); // 4
}
```

**4. Compile and serve**

```bash
dart compile js bin/main.dart -o web/main.dart.js
```

Your HTML loads the bridge before the compiled Dart:

```html
<script src="dart_monty_bridge.js"></script>
<script src="main.dart.js"></script>
```

Serve with COOP/COEP headers (required for SharedArrayBuffer):

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Each WASM session uses ~16 MB of memory. Resource limits and
`Worker.terminate()` prevent stuck scripts.

## Usage

### MontyValue: Rich Type Conversions

`MontyValue.fromJson(json)` strictly converts JSON from the interpreter into
typed sealed subclasses. `MontyValue.fromDart(value)` converts Dart values
(including `DateTime` and `Duration`) into `MontyValue` — it throws
`ArgumentError` on unsupported types rather than silently coercing.

`dartValue` returns native Dart types: `DateTime` for `MontyDate` and
`MontyDatetime`, `Duration` for `MontyTimedelta`.

```dart
final result = await monty.run('import datetime; datetime.date(2024, 1, 15)');
final date = result.value!.dartValue; // DateTime(2024, 1, 15)

final td = await monty.run('import datetime; datetime.timedelta(days=5)');
final dur = td.value!.dartValue; // Duration(days: 5)
```

### Resource Limits

```dart
final limited = await monty.run(
  'sum(range(100))',
  limits: const MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
);
print(limited.value); // 4950
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

### Bridge and Plugin System

The `start()`/`resume()` loop above is the low-level platform interface.
For real applications, the bridge module provides a higher-level API
that handles the dispatch loop, argument coercion, and event streaming
automatically.

**`DefaultMontyBridge`** wraps the dispatch loop and emits a
`Stream<BridgeEvent>` — tool calls, text output, and lifecycle events.
`MontyBridge.registerOs()` is part of the abstract interface,
so all bridge implementations support OS call dispatch.

```dart
import 'package:dart_monty/dart_monty_bridge.dart';

final bridge = DefaultMontyBridge(platform: Monty());

// Register an OS provider on the bridge
bridge.registerOs(defaultSandboxOs());

// Register host functions directly on the bridge
bridge.register(HostFunction(
  schema: const HostFunctionSchema(
    name: 'get_price',
    description: 'Get stock price by ticker symbol.',
    params: [HostParam(name: 'symbol', type: HostParamType.string)],
  ),
  handler: (args) async => 42.50,
));

// Execute — bridge handles the dispatch loop for you
await for (final event in bridge.execute('price = get_price("AAPL")')) {
  switch (event) {
    case BridgeToolCallResult(:final name, :final result):
      print('$name returned: $result');
    case BridgeTextContent(:final delta):
      print('Output: $delta');
    case BridgeRunFinished():
      print('Done');
    default:
      break;
  }
}

await bridge.dispose();
```

**`MontyPlugin`** groups related host functions under a validated namespace.
**`PluginRegistry`** collects plugins with collision detection and wires
them onto a bridge:

```dart
class WeatherPlugin extends MontyPlugin {
  @override
  String get namespace => 'weather';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'weather_forecast',
        description: 'Get weather forecast for a city.',
        params: [HostParam(name: 'city', type: HostParamType.string)],
      ),
      handler: (args) async => {'temp': 72, 'condition': 'sunny'},
    ),
  ];
}

final registry = PluginRegistry()..register(WeatherPlugin());
await registry.attachTo(bridge); // registers functions + introspection builtins
```

Plugins enforce `namespace_` prefixes on function names (e.g., `weather_forecast`),
provide lifecycle hooks (`onRegister`, `onDispose`), and auto-generate
`list_functions` / `help` introspection builtins so Python code can discover
available tools at runtime.

### Error Handling

dart_monty uses a sealed `MontyError` hierarchy for structured error handling.
See [docs/error-hierarchy.md](docs/error-hierarchy.md) for the full type tree and
propagation details.

```dart
import 'package:dart_monty/dart_monty.dart';

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

### Stateful Sessions

`MontySession` persists Python globals across multiple `run()` calls using
snapshot/restore under the hood:

```dart
import 'package:dart_monty/dart_monty.dart';

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
| **One-shot evaluation** (`Monty.exec()`) | Covered | Create, run, dispose in one call |
| **External functions** (host-provided callables) | Covered | `start()` / `resume()` / `resumeWithError()` |
| **Resource limits** (time, memory, recursion depth) | Covered | `MontyLimits` on `run()` and `start()` |
| **Print capture** (`print()` output collection) | Covered | `MontyResult.printOutput` |
| **Snapshot / restore** (`MontyRun::dump/load`) | Covered | Compile-once, run-many pattern |
| **Exception model** (excType, traceback, stack frames) | Covered | Full `MontyException` with `StackFrame` list |
| **Call metadata** (kwargs, callId, methodCall, scriptName) | Covered | Structured external call context |
| **Error hierarchy** (sealed `MontyError` with 5 subtypes) | Covered | Script, Panic, Crash, Disposed, Resource |
| **Multi-session** (WASM Worker pool) | Covered | `createSession`/`disposeSession`, 16 MB per session |
| **Async / futures** (`asyncio.gather`, concurrent calls) | Covered | `resumeAsFuture()`, `resolveFutures()` on both FFI and WASM |
| **Standard library modules** (`math`, `re`, `json`, `datetime`) | Partial | Only `math`, `re`, `json`, `datetime` — other stdlib modules are not available |
| **Rich types** (tuple, set, bytes, dataclass, namedtuple, path, date, datetime, timedelta, timezone) | Covered | Full `MontyValue` sealed hierarchy with typed subclasses |
| **OS calls** (`os.getenv`, `os.environ`, `pathlib`, `datetime.now`) | Covered | `OsProvider` via bridge with platform-conditional implementations |
| REPL (stateful sessions, `feed()`, persistence) | Planned | `MontyRepl` multi-step sessions |
| Print streaming (real-time callback) | Planned | Currently batch-only after execution |
| Advanced limits (allocations, GC interval, `runNoLimits`) | Planned | Extended `ResourceTracker` surface |
| Type checking (static analysis before execution) | Planned | ty / Red Knot integration |
| Progress serialization (suspend/resume across restarts) | Planned | `RunProgress::dump/load` |
| Platform expansion (Windows, iOS, Android) | Planned | macOS + Linux + Web today |

## Architecture

See [docs/architecture.md](docs/architecture.md) for the overview, with links to
detailed documentation:

- [OsCall / VFS Layer](docs/oscall-vfs.md) — Handler hierarchy, platform defaults, call flow
- [Error Hierarchy](docs/error-hierarchy.md) — Sealed types, propagation through boundaries
- [Native Crate Architecture](docs/native-crate.md) — Handle lifecycle, FFI boundary, tracker abstraction
- [Internals](docs/internals.md) — State machine, memory contracts, execution paths, testing

Since v0.20.0, dart_monty is a single consolidated package (previously
eight sub-packages). It selects the native or web backend at compile time
via conditional imports — no Flutter required. Internal modules:

| Module | Path | Description |
|--------|------|-------------|
| Platform interface | `lib/src/platform/` | Abstract contract (`MontyPlatform`), shared types, SPI for backend authors |
| FFI | `lib/src/ffi/` | Native FFI bindings (`dart:ffi` -> Rust shared library) |
| WASM | `lib/src/wasm/` | WASM bindings (`dart:js_interop` -> Web Worker) |
| Bridge | `lib/src/bridge/` | High-level bridge — `DefaultMontyBridge`, `BridgeEvent` streams, `MontyPlugin` / `PluginRegistry` |

Everything is pure Dart and works in CLI tools, server-side Dart, and
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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, gate scripts,
and CI details.

## License

MIT License. See [LICENSE](LICENSE).
