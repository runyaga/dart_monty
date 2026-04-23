# dart_monty

<p align="center">
  <img src="docs/assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

[Live Demo](https://runyaga.github.io/dart_monty/) | [Documentation](https://runyaga.github.io/dart_monty/help.html) | [GitHub](https://github.com/runyaga/dart_monty)

Sandboxed Python interpreter for Dart and Flutter. Run Python from native, web, and mobile — one package, every platform.

## Quick Start

First, add `dart_monty` to your `pubspec.yaml`:

```bash
dart pub add dart_monty
```

Then, import the package in your Dart code:

```dart
import 'package:dart_monty/dart_monty.dart';
```

Now you can use `dart_monty` in three ways:

**1. One-shot execution**

For simple, stateless execution, use the static `Monty.run()` method:

```dart
Future<void> main() async {
  final result = await Monty.run('2 + 2');
  print(result.value); // 4
}
```

**2. Stateful REPL**

For interactive, stateful sessions, use a `MontyRepl`:

```dart
Future<void> main() async {
  final repl = MontyRepl();
  await repl.feed('x = 42');
  await repl.feed('def double(n): return n * 2');
  final result = await repl.feed('double(x)');
  print(result.value); // MontyInt(84)
  repl.dispose();
}
```

**3. Runtime with extensions**

For more advanced use cases, create a `MontyRuntime` to manage extensions and sessions:

```dart
Future<void> main() async {
  final runtime = MontyRuntime(
    extensions: [JinjaTemplateExtension(), MessageBusExtension()],
  );
  final result = await runtime.run(
    "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
  );
  print(result.value); // 'Hello World!'
  runtime.dispose();
}
```

## Documentation

- [**Installation**](docs/user/install.md) — Add to your project
- [**Overview**](docs/help.md) — API summary and quick start
- [**Architecture**](docs/architecture/overview.md) — Module structure and internals
- [**REPL Guide**](docs/user/repl.md) — Stateful interactive execution
- [**Extensions**](docs/user/extensions.md) — Template, MessageBus, Sandbox
- [**Contributor Setup**](docs/contributor/setup.md) — Build and test the library

## License

MIT License. See [LICENSE](LICENSE).
