# dart_monty

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)

Flutter plugin that exposes the [Monty](https://github.com/pydantic/monty)
sandboxed Python interpreter to Dart and Flutter apps.

Run Python code from Dart — on desktop, mobile, and web — with resource
limits, iterative execution, and snapshot/restore support.

## Status

| Milestone | Description | Status |
|-----------|-------------|--------|
| M1 | Platform interface (value types, contract, mock) | Done |
| M2 | Rust C FFI layer + WASM build | Done |
| M3A | Native FFI package (`dart_monty_ffi`) | Done |
| M3B | Web viability spike (GO/NO-GO) | Done — **GO** |
| M3C | Python compatibility ladder + cross-path parity | Done |
| M4 | Dart WASM package (`dart_monty_wasm`, browser) | Done |
| M5 | Flutter desktop plugin (macOS + Linux) | Done |
| M6 | Flutter web plugin | Planned |
| M7 | Windows + iOS + Android | Planned |
| M8 | Hardening, benchmarks, full test matrix | Planned |
| M9 | REPL, type checking, DevTools extension | Planned |

See [PLAN.md](PLAN.md) for the full roadmap.

## Try It

### Native (desktop)

Runs Python from Dart via FFI into the Rust native library.

**Prerequisites:** Dart SDK >= 3.5.0, Rust stable

```bash
bash example/native/run.sh
```

<details>
<summary>Expected output</summary>

```text
── Simple expression ──
  2 + 2 = 4
  Memory: 0 bytes

── Multi-line code ──
  fib(10) = 55

── Resource limits ──
  "hello " * 3 = hello hello hello

── Error handling ──
  Caught: ZeroDivisionError: division by zero

── Iterative execution ──
  Python called: fetch([https://example.com])
  Result: 29

── Error injection ──
  Injecting error into Python...
  Result: caught: network timeout
```

</details>

### Web (browser)

Runs Python from Dart compiled to JS, via a Web Worker hosting the WASM
interpreter. Opens in your default browser.

**Prerequisites:** Dart SDK >= 3.5.0, Node.js >= 20, Google Chrome

```bash
bash example/web/run.sh
```

<details>
<summary>Expected output (in browser and DevTools console)</summary>

```text
=== dart_monty Web Example ===
Worker initialized.

── Simple expression ──
  2 + 2 = 4

── Multi-line code ──
  fib(10) = 55

── String result ──
  "hello " * 3 = hello hello hello

── Error handling ──
  1/0 → error: division by zero

── Iterative execution ──
  start() → state=pending, fn=fetch
  resume() → state=complete, value=<html>Hello from Dart!</html>

── Error injection ──
  start() → state=pending
  resumeWithError() → value=caught: network timeout

=== All examples complete ===
```

</details>

### Manual steps (without run scripts)

<details>
<summary>Native — manual</summary>

```bash
# 1. Build the Rust native library
cd native && cargo build --release && cd ..

# 2. Install Dart deps
cd example/native && dart pub get

# 3. Run (macOS — use .so on Linux)
DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
  dart run bin/main.dart
```

</details>

<details>
<summary>Web — manual</summary>

```bash
# 1. Build the JS bridge + WASM assets
cd packages/dart_monty_wasm/js && npm install && npm run build && cd ../../..

# 2. Install Dart deps and compile to JS
cd example/web && dart pub get
dart compile js bin/main.dart -o web/main.dart.js

# 3. Copy assets alongside the HTML
cp ../../packages/dart_monty_wasm/assets/dart_monty_bridge.js web/
cp ../../packages/dart_monty_wasm/assets/dart_monty_worker.js web/
cp ../../packages/dart_monty_wasm/assets/wasi-worker-browser.mjs web/
cp ../../packages/dart_monty_wasm/assets/*.wasm web/

# 4. Serve with COOP/COEP headers (required for SharedArrayBuffer)
python3 -c "
import http.server, functools
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()
handler = functools.partial(H, directory='web')
http.server.HTTPServer(('127.0.0.1', 8088), handler).serve_forever()
"
# 5. Open http://localhost:8088/index.html
```

</details>

## Architecture

Federated plugin with four packages and two execution paths:

```text
dart_monty                           # App-facing API (M5+)
  ├── dart_monty_platform_interface  # Abstract contract (pure Dart)
  ├── dart_monty_ffi                 # Desktop/mobile via dart:ffi → Rust → C
  └── dart_monty_wasm               # Browser via dart:js_interop → WASM Worker
native/                              # Rust crate: C API wrapper around Monty
example/
  ├── native/                        # Desktop FFI example
  └── web/                           # Browser WASM example
test/fixtures/python_ladder/         # Cross-platform parity fixtures
```

### Native Path (desktop/mobile)

```text
Dart app
  → MontyFfi (implements MontyPlatform)
    → dart:ffi (DynamicLibrary)
      → libdart_monty_native.{dylib,so,dll}
        → Monty Rust interpreter (17 extern "C" functions)
```

### Web Path (browser)

```text
Dart app (compiled to JS)
  → MontyWasm (implements MontyPlatform)
    → dart:js_interop → DartMontyBridge
      → Web Worker (dart_monty_worker.js)
        → @pydantic/monty WASM (12 MB, NAPI-RS)
          → wasi-worker-browser.mjs (SharedArrayBuffer threads)
```

The Web Worker architecture bypasses Chrome's 8 MB synchronous WASM
compilation limit. COOP/COEP HTTP headers are required for
SharedArrayBuffer support.

### Cross-Platform Parity

Both execution paths produce identical results, verified via the
**Python Compatibility Ladder** — JSON test fixtures across 6 tiers
(expressions, variables, control flow, functions, errors, external
functions). See [M3C milestone](docs/milestones/M3C.md) for details.

## API

Both backends implement the same `MontyPlatform` interface:

```dart
// Simple execution
final result = await monty.run('2 + 2');
print(result.value); // 4

// With resource limits
final result = await monty.run(
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

## Development

### Prerequisites

- Dart SDK >= 3.5.0
- Rust stable (for native builds)
- Node.js >= 20 (for WASM JS bridge)
- Python 3.12+ (for tooling scripts)

### Quick Start

```bash
flutter pub get
dart format .
python3 tool/analyze_packages.py
cd packages/dart_monty_platform_interface && dart test
```

### Gate Scripts

```bash
bash tool/test_m1.sh          # M1: platform interface
bash tool/test_m2.sh          # M2: Rust + WASM
bash tool/test_m3a.sh         # M3A: FFI package
bash tool/test_wasm.sh        # M4: WASM package (unit + Chrome integration)
bash tool/test_python_ladder.sh       # Python ladder (all backends)
bash tool/test_cross_path_parity.sh   # JSONL parity diff
```

### CI

GitHub Actions run on every push and PR to `main`:

- **Lint** — format + ffigen + analyze all sub-packages
- **Test** — per-package with 90% coverage gate (platform\_interface, ffi, wasm)
- **Rust** — fmt + clippy + test + tarpaulin coverage (90% gate)
- **Build WASM** — `cargo build --target wasm32-wasip1-threads`
- **Build JS wrapper** — npm install + esbuild bridge/worker
- **Build native** — Ubuntu + macOS matrix
- **DCM** — Dart Code Metrics
- **Markdown** — pymarkdown scan
- **Security** — gitleaks secret scanning

## License

Private. Not published to pub.dev.
