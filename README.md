# dart_monty

Flutter plugin that exposes the [Monty](https://github.com/pydantic/monty)
sandboxed Python interpreter to Dart and Flutter apps.

Run Python code from Dart — on desktop, mobile, and web — with resource
limits, iterative execution, and snapshot/restore support.

## Status

**Work in progress.** M3C (cross-platform parity) is complete — fixtures
prove identical results on native FFI and web WASM. Next up: M4 (Dart
WASM package).
See [PLAN.md](PLAN.md) for the full roadmap.

| Milestone | Description | Status |
|-----------|-------------|--------|
| M1 | Platform interface (value types, contract, mock) | Done |
| M2 | Rust C FFI layer + WASM build | Done |
| M3A | Native FFI package (`dart_monty_ffi`) | Done |
| M3B | Web viability spike (GO/NO-GO) | Done — **GO** |
| M3C | Python compatibility ladder + cross-path parity | Done |
| M4 | Dart WASM package (pure Dart, browser) | Next |
| M5 | Flutter desktop plugin (macOS + Linux) | Planned |
| M6 | Flutter web plugin | Planned |
| M7 | Windows + iOS + Android | Planned |
| M8 | Hardening, benchmarks, full test matrix | Planned |
| M9 | REPL, type checking, DevTools extension | Planned |

## Architecture

Federated plugin with four packages and two execution paths:

```text
dart_monty                           # App-facing API (M5+)
  ├── dart_monty_platform_interface  # Abstract contract (pure Dart)
  ├── dart_monty_ffi                 # Desktop/mobile via dart:ffi → Rust → C
  └── dart_monty_web                 # Browser via dart:js_interop → WASM
native/                              # Rust crate: C API wrapper around Monty
spike/web_test/                      # Web spike + ladder runner
test/fixtures/python_ladder/         # Cross-platform parity fixtures
```

### Native Path (desktop/mobile)

```text
Dart app
  → dart_monty_ffi (MontyFfi implements MontyPlatform)
    → dart:ffi (DynamicLibrary)
      → native/libdart_monty_native.{dylib,so,dll}
        → Monty Rust interpreter (17 extern "C" functions)
```

### Web Path (browser)

```text
Dart app (compiled to JS)
  → dart_monty_web (dart:js_interop)
    → monty_glue.js (window.montyBridge, postMessage)
      → Web Worker (monty_worker.js)
        → @pydantic/monty WASM (12MB, NAPI-RS)
          → wasi-worker-browser.mjs (SharedArrayBuffer threads)
```

The Web Worker architecture bypasses Chrome's 8MB synchronous WASM
compilation limit. COOP/COEP HTTP headers are required for
SharedArrayBuffer support.

### Cross-Platform Parity

Both execution paths are verified to produce identical results via the
**Python Compatibility Ladder** — JSON test fixtures across 6 tiers:

| Tier | Feature |
|------|---------|
| 1 | Expressions (arithmetic, bitwise, unicode, None) |
| 2 | Variables & collections (slicing, nesting, membership) |
| 3 | Control flow (loops, comprehensions, ternary) |
| 4 | Functions (recursion, closures, varargs, lambda) |
| 5 | Error handling (try/except/finally, raise, uncaught) |
| 6 | External functions (start/resume, sequential, error) |

A native Dart test runner and a web Dart-to-JS runner execute the same
fixtures; JSONL output is diffed for parity. See
[M3C milestone](docs/milestones/M3C.md) for details.

## Planned Usage

```dart
import 'package:dart_monty/dart_monty.dart';

final result = await DartMonty.run(
  'x * 2 + 1',
  inputs: {'x': 21},
  limits: MontyLimits(timeoutMs: 5000),
);

print(result.value); // 43
print(result.usage.timeElapsedMs); // ~2
```

### Iterative Execution (External Functions)

```dart
var progress = await DartMonty.start(
  'fetch("https://example.com")',
  externalFunctions: ['fetch'],
);

while (progress is MontyPending) {
  final data = await http.get(progress.arguments.first as String);
  progress = await DartMonty.resume(data.body);
}

final complete = progress as MontyComplete;
print(complete.result.value);
```

## Development

### Prerequisites

- Dart SDK >= 3.5.0
- Flutter SDK >= 3.24.0 (M5+)
- Rust stable (M2+)
- Python 3.12+ (for tooling scripts)

### Quick Start

```bash
flutter pub get
dart format .
python3 tool/analyze_packages.py
cd packages/dart_monty_platform_interface && dart test
```

### Pre-commit Hooks

Install [pre-commit](https://pre-commit.com/) and run:

```bash
pre-commit install
```

Hooks run Dart format, package analysis, DCM, tests, pymarkdown, and
gitleaks on every commit.

### CI

GitHub Actions run on every push and PR to `main`:

- **Lint** — format + ffigen + analyze all sub-packages
- **Test** — per-package with 90% coverage gate (platform\_interface, ffi)
- **Rust** — fmt + clippy + test + tarpaulin coverage
- **Build WASM** — `cargo build --target wasm32-wasip1-threads`
- **Build native** — Ubuntu + macOS matrix
- **DCM** — Dart Code Metrics (commercial)
- **Markdown** — pymarkdown scan
- **Security** — gitleaks secret scanning

## License

Private. Not published to pub.dev.
