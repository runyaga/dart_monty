# dart_monty

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

**[Live Demo](https://runyaga.github.io/dart_monty/)** — try it in your browser

Flutter plugin that exposes the [Monty](https://github.com/pydantic/monty)
sandboxed Python interpreter to Dart and Flutter apps.

Run Python code from Dart — on desktop, mobile, and web — with resource
limits, iterative execution, and snapshot/restore support.

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

// Cleanup
await monty.dispose();
```

## Architecture

Federated plugin with six packages:

```text
dart_monty                           # App-facing API (Flutter plugin)
  dart_monty_platform_interface      # Abstract contract (pure Dart)
  dart_monty_ffi                     # Native FFI bindings (dart:ffi -> Rust)
  dart_monty_wasm                    # WASM bindings (dart:js_interop -> Web Worker)
  dart_monty_desktop                 # Desktop plugin (macOS/Linux, Isolate)
  dart_monty_web                     # Web plugin (browser, script injection)
```

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

See [PLAN.md](PLAN.md) for engineering milestones and quality gates.

## License

MIT License. See [LICENSE](LICENSE).
