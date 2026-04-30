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

On Flutter, add the asset stanza so the bundler includes
`dart_monty_core`'s WASM/JS bridge files (plain-Dart consumers can
skip this):

```yaml
flutter:
  assets:
    - package: dart_monty_core
```

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

On Flutter Web, initialise the bridge before first use:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DartMonty.ensureInitialized(); // loads bridge on web; no-op native
  runApp(const MyApp());
}
```

No `<script>` tag in `web/index.html` is required —
`DartMonty.ensureInitialized()` injects the bridge dynamically.

Now you can use `dart_monty` in three ways:

**1. One-shot execution**

For simple, stateless execution, use the static `Monty.exec()` method:

```dart
Future<void> main() async {
  final result = await Monty.exec('2 + 2');
  print(result.value); // 4
}
```

**2. Stateful REPL**

For interactive, stateful sessions, use a `MontyRepl`:

```dart
Future<void> main() async {
  final repl = MontyRepl();
  await repl.feedRun('x = 42');
  await repl.feedRun('def double(n): return n * 2');
  final result = await repl.feedRun('double(x)');
  print(result.value); // MontyInt(84)
  await repl.dispose();
}
```

**3. Runtime with extensions**

For more advanced use cases, create a `MontyRuntime` to manage extensions and sessions:

```dart
Future<void> main() async {
  final runtime = MontyRuntime(
    extensions: [JinjaTemplateExtension(), MessageBusExtension()],
  );
  final result = await runtime.execute(
    "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
  ).result;
  print(result.value); // 'Hello World!'
  await runtime.dispose();
}
```

## Examples

Runnable end-to-end demos, all platform-agnostic (FFI on the VM, WASM
in Chrome — `Monty` dispatches to the same Rust ABI on every backend):

| File | What it shows |
|---|---|
| [`example/example.dart`](example/example.dart) | Minimal `Monty.exec` one-shots, including error handling. |
| [`example/type_check_demo.dart`](example/type_check_demo.dart) | `Monty.typeCheck` for static type analysis — clean code, type errors, `prefixCode` for declaring external function shapes. |
| [`example/dataclass_demo.dart`](example/dataclass_demo.dart) | Stateful dataclass round-trip across `MontyRuntime.execute` calls — produce, attribute-access, return, and re-bind a `@dataclass`, hydrating into a typed Dart `User` on the way back. |

Run any of them with `dart run example/<file>.dart` from the repo root.
For the native and web runners (with built Rust library and a COOP/COEP
server), see `example/native/run.sh` and `example/web/run.sh`.

## Documentation

- [**Installation**](docs/user/install.md) — Add to your project
- [**Overview**](docs/help.md) — API summary and quick start
- [**Architecture**](docs/architecture/overview.md) — Module structure and internals
- [**REPL Guide**](docs/user/repl.md) — Stateful interactive execution
- [**Extensions**](docs/user/extensions.md) — Template, MessageBus, Sandbox
- [**Contributing**](CONTRIBUTING.md) — Build, run tests, gate scripts, release process
- [**Contributor Setup**](docs/contributor/setup.md) — Toolchain install (Rust, Dart, Python)

## License

MIT License. See [LICENSE](LICENSE).
