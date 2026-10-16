# dart_monty

<p align="center">
  <img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

[Live Demo](https://runyaga.github.io/dart_monty/) | [Documentation](https://github.com/runyaga/dart_monty/tree/main/docs) | [GitHub](https://github.com/runyaga/dart_monty)

Sandboxed Python interpreter for Dart and Flutter. Run Python from native, web, and mobile — one package, every platform.

## Quick Start

### Install

```sh
dart pub add dart_monty
```

The low-level bindings (`dart_monty_core`) are pulled in transitively.

Flutter Web uses the worker assets declared by core's `flutter.assets`
stanza and core's asset-path probe. Both packages remain pure Dart; no
Flutter SDK dependency or initialization call is added to core.
See [installation](docs/user/install.md#flutter-web) for bundling details.

For local development against a worktree, override with `path:`
deps:

```yaml
dependencies:
  dart_monty:
    path: /path/to/dart_monty
  dart_monty_core:
    path: /path/to/dart_monty_core
```

Then import the package:

```dart
import 'package:dart_monty/dart_monty.dart';
```

Now you can use `dart_monty` in three ways:

**1. One-shot execution**

Use a pool and a session for execution:

```dart
final value = await Monty.withPool(
  (pool) => pool.withSession((session) => session.feedRun('2 + 2')),
);
print(value.dartValue); // 4
```

**2. Stateful session**

```dart
await Monty.withPool((pool) async {
  final session = await pool.checkout(typeCheck: true);
  try {
    await session.feedRun('x: int = 42');
    final result = await session.feedRun('x * 2');
    print(result.dartValue); // 84
  } finally {
    await session.close();
  }
});
```

Type checking happens before each feed runs. A rejected feed throws
`MontyTypingError`, available from core's public library. See the
[type-checking example](example/type_check_demo.dart) for `typeCheckStubs`.

**3. Runtime with host functions and extensions**

`MontyRuntime` manages host functions, extensions, and long-lived sessions.
Register `HostFunction`s to expose Dart callbacks to Python:

```dart
Future<void> main() async {
  final runtime = (await MontyRuntime.start())
    ..register(HostFunction(
      schema: const HostFunctionSchema(
        name: 'fetch',
        description: 'Fetch a URL',
        params: [HostParam(name: 'url', type: HostParamType.string)],
      ),
      // DispatchMode.future lets Python `await fetch(url)` directly.
      // asyncio.gather over multiple calls runs them concurrently.
      dispatch: DispatchMode.future,
      handler: (args, _) async => httpClient.get(args['url']! as String),
    ));

  final result = await runtime.execute(
    'await fetch(base_url)',
    inputs: {'base_url': 'https://example.com/api'},
  ).result;
  print(result.dartValue);
  await runtime.dispose();
}
```

For plugin-style wiring, pass `extensions`:

```dart
final runtime = await MontyRuntime.start(
  extensions: [EventLoopExtension()],
);
```

## Examples

Runnable end-to-end demos, all platform-agnostic (FFI on the VM, WASM
in Chrome — `Monty` dispatches to the same Rust ABI on every backend):

| File | What it shows |
|---|---|
| [`example/example.dart`](example/example.dart) | Minimal pool/session one-shots, including error handling. |
| [`example/type_check_demo.dart`](example/type_check_demo.dart) | Session type checking with `checkout(typeCheck: true)` and `typeCheckStubs`. |
| [`example/dataclass_demo.dart`](example/dataclass_demo.dart) | Stateful dataclass round-trip across `MontyRuntime.execute` calls — produce, attribute-access, return, and re-bind a `@dataclass`, hydrating into a typed Dart `User` on the way back. |

Run any of them with `dart run example/<file>.dart` from the repo root.
For the native and web runners (with built Rust library and a COOP/COEP
server), see `example/native/run.sh` and `example/web/run.sh`.

## Documentation

- [**Installation**](docs/user/install.md) — Add to your project
- [**Overview**](docs/help.md) — API summary and quick start
- [**Architecture**](docs/architecture/overview.md) — Module structure and internals
- [**REPL Guide**](docs/user/repl.md) — Stateful interactive execution
- [**Extensions**](docs/user/extensions.md) — EventLoop, Sandbox
- [**Contributing**](CONTRIBUTING.md) — Build, run tests, gate scripts, release process
- [**Contributor Setup**](docs/contributor/setup.md) — Toolchain install (Rust, Dart, Python)

## Stability and versioning

This package does **not** follow semantic versioning. Breaking changes can
land in any release. The [CHANGELOG](CHANGELOG.md) is kept up-to-date with
every breaking change, so pin to a specific version and read the changelog
before upgrading.

We expect to stabilise the API and adopt semver when the package goes into
production — roughly 1–3 months from now. If you are planning to depend on
this package, please open an issue so we can factor your use-case into the
stabilisation work.

## License

MIT License. See [LICENSE](LICENSE).
