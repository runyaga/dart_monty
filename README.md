# dart_monty

Flutter plugin that exposes the [Monty](https://github.com/pydantic/monty)
sandboxed Python interpreter to Dart and Flutter apps.

Run Python code from Dart — on desktop, mobile, and web — with resource
limits, iterative execution, and snapshot/restore support.

## Status

**Work in progress.** M1 (platform interface) is complete. See
[PLAN.md](PLAN.md) for the full roadmap.

| Milestone | Description | Status |
|-----------|-------------|--------|
| M1 | Platform interface (value types, contract, mock) | Done |
| M2 | Rust C FFI layer + WASM build | Planned |
| M3 | Dart FFI bindings + web spike + Python ladder | Planned |
| M4 | Dart WASM package (pure Dart, browser) | Planned |
| M5 | Flutter desktop plugin (macOS + Linux) | Planned |
| M6 | Flutter web plugin | Planned |
| M7 | Windows + iOS + Android | Planned |
| M8 | Hardening, benchmarks, full test matrix | Planned |
| M9 | REPL, type checking, DevTools extension | Planned |

## Architecture

Federated plugin with four packages:

```text
dart_monty                        # App-facing API
  ├── dart_monty_platform_interface  # Abstract contract (pure Dart)
  ├── dart_monty_ffi                 # Desktop/mobile via dart:ffi → Rust → C
  └── dart_monty_web                 # Browser via dart:js_interop → WASM
native/                           # Rust crate wrapping Monty as a C library
```

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

- **Lint** — format + analyze all sub-packages
- **DCM** — Dart Code Metrics (commercial)
- **Markdown** — pymarkdown scan
- **Test** — per-package with 90% coverage gate
- **Security** — gitleaks secret scanning

## License

Private. Not published to pub.dev.
