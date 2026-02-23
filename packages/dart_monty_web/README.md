# dart_monty_web

**Flutter plugin** — web platform registration for dart_monty. Delegates to `dart_monty_wasm` for WASM-based Python execution in the browser.

Requires Flutter. This package is not intended for direct use. Import `dart_monty` instead — the federated plugin system selects this package automatically when building for web.

## How It Works

`DartMontyWeb` registers itself as the `MontyPlatform` instance via Flutter's `flutter_web_plugins` system. All execution is delegated to `MontyWasm` from the `dart_monty_wasm` package.

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
