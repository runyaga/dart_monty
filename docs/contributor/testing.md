# Testing Guide

Everything you need to know about testing `dart_monty` across native and web.

## Quick Reference

```bash
dart test                                    # All unit tests (fast)
dart test test/platform/                     # Platform interface tests
dart test test/ffi/                          # FFI unit tests
dart test test/wasm/                         # WASM unit tests (VM-only, no browser)
dart test test/bridge/                       # Bridge unit tests

# Integration tests (Native)
dart test --run-skipped --tags=ladder         # Python ladder fixtures only
dart test --run-skipped --tags=integration    # All integration tests

# All-in-one quality gate
bash tool/gate.sh
```

## Unit Tests (VM)

Unit tests run in the standard Dart VM and are fast. They cover logic that
doesn't require a real WASM environment or native library (or they use
mocks).

## FFI Integration Tests (Native)

The FFI module uses Dart's native assets system (`hook/build.dart`) to
auto-build or download the native library. `dart test` triggers the hook
automatically. Integration and ladder tests are **skipped by default** via
`dart_test.yaml` to keep `dart test` fast.

Use `--run-skipped` to execute them.

## WASM Integration Tests (Browser)

WASM integration tests (`test/wasm/integration/`) run in headless Chrome
with COOP/COEP headers. They are NOT included in `dart test`.

### Automated Run

```bash
bash tool/test_python_ladder.sh    # Builds, serves, runs in headless Chrome
```

### Manual Run

1. **Build WASM:** `cd native && cargo build --release --target wasm32-wasip1`
2. **Compile Runner:** `dart compile js test/wasm/integration/python_ladder_runner.dart -o test/wasm/integration/web/ladder_runner.dart.js`
3. **Copy Assets:** Copy `dart_monty_bridge.js`, `dart_monty_worker.js`, and `.wasm` files to the integration web directory.
4. **Serve:** Use a server that provides COOP/COEP headers (required for `SharedArrayBuffer`).

## Cross-Platform Parity

Both the native FFI and web WASM paths are verified to produce identical
results via JSON test fixtures in `test/fixtures/python_ladder/`. The
`tool/test_cross_path_parity.sh` script runs both runners and diffs their
output.

## Manual Browser Testing

To test in a real browser, use the Python-based COOP/COEP server:

```python
# Start the COOP/COEP server
python3 -c "
import http.server, functools
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()
handler = functools.partial(H, directory='web')
http.server.HTTPServer(('127.0.0.1', 8099), handler).serve_forever()
"
```
