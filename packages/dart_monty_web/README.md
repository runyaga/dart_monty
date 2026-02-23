# dart_monty_web

Part of [dart_monty](https://github.com/runyaga/dart_monty) — pure Dart bindings for [Monty](https://github.com/pydantic/monty), a restricted, sandboxed Python interpreter built in Rust.

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

**Flutter plugin** — web platform registration for dart_monty. Delegates to `dart_monty_wasm` for WASM-based Python execution in the browser.

Requires Flutter. This package is not intended for direct use. Import `dart_monty` instead — the federated plugin system selects this package automatically when building for web.

## How It Works

`DartMontyWeb` registers itself as the `MontyPlatform` instance via Flutter's `flutter_web_plugins` system. All execution is delegated to `MontyWasm` from the `dart_monty_wasm` package.

See the [main dart_monty repository](https://github.com/runyaga/dart_monty) for full documentation.
