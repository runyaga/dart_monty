# Plugin System — Monty Platform

How the dart_monty packages fit together, how to use the platform API,
and how host functions turn Dart code into a Python-callable library.

## Package Overview

dart_monty is a pure Dart package. The `Monty()` convenience class
selects the native or web backend at compile time via conditional imports
— no Flutter required:

```text
Your app / CLI
     │
     ▼
Monty()                         ← dart_monty (conditional import factory)
     │
     ├── MontyFfi               ← dart_monty_ffi (desktop, native)
     │     └── NativeBindingsFfi    → dart:ffi → libdart_monty_native.dylib
     │
     ├── MontyWasm              ← dart_monty_wasm (browser)
     │     └── WasmBindingsJs       → dart:js_interop → Worker → WASM
     │
     └── MontyNative            ← dart_monty_ffi (Isolate wrapper)
           └── NativeIsolateBindings → Isolate → MontyFfi
```

**`MontyPlatform`** is the abstract contract. `MontyFfi` and `MontyWasm`
are the two concrete backends. `MontyNative` wraps `MontyFfi` in a
background Isolate for long-running executions (keeps the UI thread free).

All backends produce identical `MontyResult`, `MontyProgress`, and
`MontyException` types for the same Python input.

## Quick Start

### One-shot execution

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final monty = Monty();

  final result = await monty.run('2 ** 10');
  print(result.value); // 1024

  await monty.dispose();
}
```

### Stateful sessions (REPL)

`MontySession` wraps any `MontyPlatform` and persists Python globals
across calls using snapshot/restore internally:

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final monty = Monty();
  final session = MontySession(platform: monty);

  await session.run('x = 42');
  await session.run('y = x * 2');
  final result = await session.run('x + y');
  print(result.value); // 126

  session.dispose();
  await monty.dispose();
}
```

Variables defined in one `run()` carry over to the next. Only
JSON-serializable types persist (int, float, str, bool, list, dict, None).

## Host Functions — The Dispatch Loop

Host functions let Python call Dart code. This is the core integration
pattern and the key to building "libraries" for the Monty Python subset.

### The Protocol

1. **Register** external function names with `start()`
2. Python calls one of those names
3. Execution **pauses** — Dart receives a `MontyPending`
4. Dart inspects the function name and args, computes a result
5. Dart calls `resume(result)` to feed the value back
6. Repeat until `MontyComplete`

```dart
var progress = await monty.start(
  code,
  externalFunctions: ['greet', 'add', 'uppercase'],
);

while (progress is MontyPending) {
  final fn = progress.functionName;  // e.g. "greet"
  final args = progress.arguments;   // e.g. ["world"]
  final kwargs = progress.kwargs;    // e.g. {"greeting": "Hello"}

  final returnValue = dispatch(fn, args, kwargs);
  progress = await monty.resume(returnValue);
}

if (progress is MontyComplete) {
  print(progress.result.value);
}
```

### Error Handling

If the host can't fulfill a call, use `resumeWithError` instead of
`resume`. Python sees it as a runtime exception:

```dart
if (handler == null) {
  progress = await monty.resumeWithError(
    'No handler for "$fn"',
  );
  continue;
}
```

## The Bridge Layer (`dart_monty_bridge`)

The dispatch loop above is the low-level platform interface. In practice,
you don't write it by hand — `DefaultMontyBridge` handles the loop,
argument coercion, and event streaming automatically.

### `DefaultMontyBridge`

Wraps a `MontyPlatform` and emits a `Stream<BridgeEvent>` for each
execution — tool calls, text output, and lifecycle events:

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

final bridge = DefaultMontyBridge(platform: Monty());

bridge.register(HostFunction(
  schema: const HostFunctionSchema(
    name: 'get_price',
    description: 'Get stock price by ticker symbol.',
    params: [HostParam(name: 'symbol', type: HostParamType.string)],
  ),
  handler: (args) async => 42.50,
));

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

The bridge handles the `start()` → `MontyPending` → `resume()` loop
internally. You register `HostFunction`s with typed schemas and async
handlers — the bridge dispatches by name, coerces arguments, and feeds
results back.

### `HostFunction` and `HostFunctionSchema`

Each host function has a schema (name, description, typed params) and
an async handler:

```dart
HostFunction(
  schema: const HostFunctionSchema(
    name: 'fetch_data',
    description: 'Fetch JSON data from a URL.',
    params: [
      HostParam(name: 'url', type: HostParamType.string),
      HostParam(name: 'timeout', type: HostParamType.integer, isRequired: false),
    ],
  ),
  handler: (args) async {
    final url = args['url'] as String;
    final timeout = args['timeout'] as int? ?? 30;
    return await httpGet(url, timeout: timeout);
  },
)
```

Parameter types: `string`, `integer`, `float`, `boolean`, `list`, `map`.
The bridge validates and coerces arguments before calling the handler.

### `BridgeEvent` (sealed hierarchy)

The event stream covers the full execution lifecycle:

| Event | When |
|-------|------|
| `BridgeRunStarted` | Execution begins |
| `BridgeStepStarted` / `BridgeStepFinished` | Each start/resume cycle |
| `BridgeToolCallStart` | Python calls a host function |
| `BridgeToolCallArgs` | Arguments (streamed as JSON delta) |
| `BridgeToolCallResult` | Handler returned a value |
| `BridgeToolCallEnd` | Tool call complete |
| `BridgeTextStart` / `BridgeTextContent` / `BridgeTextEnd` | Print output |
| `BridgeUiRendered` | EventLoopBridge UI update |
| `BridgeRunFinished` | Execution complete (includes result) |
| `BridgeRunError` | Execution failed |
| `BridgeEventLoopWaiting` / `BridgeEventLoopResumed` | Event loop lifecycle |

## The Plugin System

For anything beyond a handful of functions, use `MontyPlugin` and
`PluginRegistry` to organize host functions into namespaced, lifecycle-
managed groups.

### `MontyPlugin`

Abstract class — each plugin declares a namespace, a list of functions,
and optional lifecycle hooks:

```dart
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

class WeatherPlugin extends MontyPlugin {
  @override
  String get namespace => 'weather';

  @override
  String? get systemPromptContext =>
      'Weather functions query a live forecast API.';

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
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'weather_alerts',
        description: 'Get active weather alerts for a region.',
        params: [HostParam(name: 'region', type: HostParamType.string)],
      ),
      handler: (args) async => [],
    ),
  ];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    // Called when attached to a bridge — initialize resources
  }

  @override
  Future<void> onDispose() async {
    // Called when session ends — clean up resources
  }
}
```

**Naming rule:** all function names must be prefixed with `{namespace}_`.
A plugin with namespace `weather` must name its functions `weather_forecast`,
`weather_alerts`, etc. This prevents collisions across plugins.

### `PluginRegistry`

Collects plugins with validation and wires them onto a bridge:

```dart
final registry = PluginRegistry()
  ..register(WeatherPlugin())
  ..register(StoragePlugin())
  ..register(MathPlugin());

final bridge = DefaultMontyBridge(platform: Monty());
await registry.attachTo(bridge);
```

`attachTo()` does three things:

1. Registers every plugin's `HostFunction`s onto the bridge
2. Calls `onRegister()` on each plugin (lifecycle hook)
3. Registers **introspection builtins** (`list_functions`, `help`) so
   Python code can discover available tools at runtime

**Validation on `register()`:**

- Namespace must be lowercase alphanumeric (`[a-z][a-z0-9_]*`), max 32 chars
- Namespace `introspection` is reserved (used by builtins)
- No duplicate namespaces across plugins
- No duplicate function names across plugins
- All function names must start with `{namespace}_`

**Disposal:**

```dart
await registry.disposeAll(); // calls onDispose() on each plugin in reverse order
```

### Introspection Builtins

When a `PluginRegistry` is attached, Python gets two free functions:

```python
# List all available functions grouped by namespace
tools = list_functions()
# {'weather': [{'name': 'weather_forecast', ...}],
#  'storage': [{'name': 'storage_get', ...}],
#  'introspection': [{'name': 'list_functions', ...}, {'name': 'help', ...}]}

# Get detailed schema for a specific function
info = help("weather_forecast")
# {'name': 'weather_forecast', 'description': '...', 'params': [...]}
```

This lets LLM-generated Python discover and use tools dynamically without
hardcoded knowledge of the available API.

### System Prompt Generation

`PluginRegistry` can auto-generate an LLM system prompt from plugin schemas:

```dart
final prompt = registry.generateSystemPrompt();
// ### weather
// Weather functions query a live forecast API.
// - `weather_forecast(city: string)`: Get weather forecast for a city.
// - `weather_alerts(region: string)`: Get active weather alerts for a region.
//
// ### storage
// ...
```

### Layers Summary

```text
┌──────────────────────────────────────────────────┐
│  PluginRegistry + MontyPlugin                    │  ← namespace validation,
│  (dart_monty_bridge)                             │    lifecycle, introspection
├──────────────────────────────────────────────────┤
│  DefaultMontyBridge + HostFunction               │  ← dispatch loop, event
│  (dart_monty_bridge)                             │    streaming, arg coercion
├──────────────────────────────────────────────────┤
│  MontyPlatform (start/resume/run)                │  ← raw platform interface
│  (dart_monty_platform_interface)                 │
├──────────────────────────────────────────────────┤
│  MontyFfi / MontyWasm                            │  ← FFI or WASM backend
│  (dart_monty_ffi / dart_monty_wasm)              │
└──────────────────────────────────────────────────┘
```

Most applications work at the top two layers. The raw platform interface
is useful for custom dispatch logic or when you need direct control over
the start/resume cycle.

## Example: Building a Dart "Library" for Python

Here's a complete example of a small math library exposed to Python
through host functions. No `import` needed on the Python side — the
functions are globals.

### Dart Side — Define and Dispatch

```dart
import 'package:dart_monty/dart_monty.dart';

/// Host function handlers — each takes (args, kwargs) and returns a value.
typedef HostHandler = Object? Function(
  List<Object?> args,
  Map<String, Object?>? kwargs,
);

final Map<String, HostHandler> mathLib = {
  'sqrt': (args, _) {
    final n = (args[0] as num).toDouble();
    return _babylonianSqrt(n);
  },
  'clamp': (args, _) {
    final value = (args[0] as num).toDouble();
    final lo = (args[1] as num).toDouble();
    final hi = (args[2] as num).toDouble();
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
  },
  'factorial': (args, _) {
    var n = args[0] as int;
    if (n < 0) return 'Error: negative input';
    var result = 1;
    while (n > 1) {
      result *= n;
      n--;
    }
    return result;
  },
  'is_prime': (args, _) {
    final n = args[0] as int;
    if (n < 2) return false;
    for (var i = 2; i * i <= n; i++) {
      if (n % i == 0) return false;
    }
    return true;
  },
};

double _babylonianSqrt(double n) {
  if (n < 0) return double.nan;
  if (n == 0) return 0;
  var guess = n / 2;
  for (var i = 0; i < 20; i++) {
    guess = (guess + n / guess) / 2;
  }
  return guess;
}

Future<void> main() async {
  final monty = Monty();

  const code = '''
a = sqrt(144)
b = clamp(150, 0, 100)
c = factorial(10)
d = is_prime(97)
(a, b, c, d)
''';

  var progress = await monty.start(
    code,
    externalFunctions: mathLib.keys.toList(),
  );

  while (progress is MontyPending) {
    final handler = mathLib[progress.functionName];
    if (handler != null) {
      final result = handler(progress.arguments, progress.kwargs);
      progress = await monty.resume(result);
    } else {
      progress = await monty.resumeWithError(
        'Unknown function: ${progress.functionName}',
      );
    }
  }

  if (progress is MontyComplete) {
    print(progress.result.value);
    // (12.0, 100, 3628800, True)
  }

  await monty.dispose();
}
```

### Python Side — Just Call Them

From Python's perspective, `sqrt`, `clamp`, `factorial`, and `is_prime`
are built-in globals:

```python
a = sqrt(144)       # 12.0
b = clamp(150, 0, 100)  # 100
c = factorial(10)   # 3628800
d = is_prime(97)    # True
(a, b, c, d)
```

No imports, no setup. The Dart dispatch loop fulfills each call.

## Example: DOM Library (Web Showcase)

The web showcase builds an entire DOM manipulation library as host
functions. Python code manipulates the browser through opaque integer
handles:

```python
app = dom_query("#sandbox")

title = dom_create("h2")
dom_text(title, "Hello from Python")
dom_style(title, "color", "#00d4ff")
dom_append(app, title)

btn = dom_create("button")
dom_text(btn, "Click me")
dom_append(app, btn)

dom_on_click(btn)  # blocks until clicked
log("Button clicked!")
```

Each `dom_*` call pauses Python, Dart manipulates the real DOM, and
resumes Python with the result (a handle, `None`, or a string).

The full host function set (`showcase.dart`) includes 29 functions across
DOM, storage, JSON, network, file I/O, and interpreter state. See
`example/web-showcase/bin/showcase.prompt.md` for the complete API
reference.

## Key Types

### `MontyResult`

Returned by `run()` and inside `MontyComplete`:

```dart
class MontyResult {
  final Object? value;          // Python return value
  final MontyException? error;  // null if success
  final MontyResourceUsage usage;
  final String? printOutput;    // captured print() output
}
```

### `MontyProgress` (sealed)

Returned by `start()` and `resume()`:

```dart
sealed class MontyProgress {}

class MontyPending extends MontyProgress {
  final String functionName;    // which host function was called
  final List<Object?> arguments;
  final Map<String, Object?>? kwargs;
  final int callId;
  final bool methodCall;
}

class MontyComplete extends MontyProgress {
  final MontyResult result;
}

class MontyResolveFutures extends MontyProgress {
  final List<int> pendingCallIds;
}
```

### `MontyLimits`

Resource constraints for sandboxed execution:

```dart
final result = await monty.run(
  code,
  limits: MontyLimits(
    timeoutMs: 5000,
    memoryBytes: 10 * 1024 * 1024,
    stackDepth: 100,
  ),
);
```

### Capability Interfaces

Not all backends support all features. Use `is` checks:

```dart
// Snapshots (FFI + WASM)
if (monty is MontySnapshotCapable) {
  final snapshot = await monty.snapshot();
  final restored = await monty.restore(snapshot);
}

// Futures (FFI + WASM)
if (monty is MontyFutureCapable) {
  progress = await monty.resumeAsFuture();
}
```

## Platform Support

| Platform | Package | Backend |
|----------|---------|---------|
| macOS, Linux | `dart_monty_ffi` | `MontyFfi` via `dart:ffi` |
| Web (browser) | `dart_monty_wasm` | `MontyWasm` via JS bridge + Worker |
| Flutter (any) | `dart_monty_ffi` | `MontyNative` (Isolate wrapper around `MontyFfi`) |

All backends implement the same `MontyPlatform` interface. Code written
against the interface works on any platform without changes.

## Testing

Mock any backend with `MockMontyPlatform`:

```dart
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';

final mock = MockMontyPlatform();
mock.runResult = MontyResult(value: 42, usage: zeroUsage);

final result = await mock.run('anything');
expect(result.value, 42);
expect(mock.lastRunCode, 'anything');
```

For iterative flows, queue progress responses:

```dart
mock.enqueueProgress(MontyPending(functionName: 'greet', arguments: ['Bob']));
mock.enqueueProgress(MontyComplete(result: MontyResult(value: 'done')));

var p = await mock.start('code', externalFunctions: ['greet']);
// p is MontyPending
p = await mock.resume('Hello, Bob!');
// p is MontyComplete
```
