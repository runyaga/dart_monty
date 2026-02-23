# dart_monty_wasm

Part of [dart_monty](https://github.com/runyaga/dart_monty) — Dart and Flutter bindings for [Monty](https://github.com/pydantic/monty), a Rust-built embeddable sandbox that runs a restricted subset of Python.

[Documentation](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty (upstream)](https://github.com/pydantic/monty)

**Pure Dart** web WASM implementation of dart_monty using `dart:js_interop` and `@pydantic/monty`. Runs the Monty Python interpreter in a Web Worker to avoid Chrome's synchronous WASM compile-size limit.

This package has no Flutter dependency and can be used in any Dart web project.

- **Flutter apps** should import `dart_monty` instead — the federated plugin selects the correct backend automatically.
- **Pure Dart web projects** can depend on this package directly to run Python via WASM in the browser.

## Architecture

```text
Dart (compiled to JS) -> MontyWasm (dart:js_interop)
  -> DartMontyBridge (monty_glue.js)
    -> Web Worker (dart_monty_worker.js)
      -> @pydantic/monty WASM (NAPI-RS)
```

## Key Classes

| Class | Description |
|-------|-------------|
| `WasmBindings` | Abstract async interface for WASM operations |
| `WasmBindingsJs` | Concrete JS interop implementation via Web Worker |
| `MontyWasm` | `MontyPlatform` implementation using `WasmBindings` |

## Requirements

The web server must send COOP/COEP headers for SharedArrayBuffer support:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
