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

```bash
dart pub add dart_monty
```

**One-shot execution**

```dart
final result = await Monty.exec('2 + 2');
print(result.value); // 4
```

**Stateful REPL**

```dart
final repl = MontyRepl();
await repl.feed('x = 42');
await repl.feed('def double(n): return n * 2');
final r = await repl.feed('double(x)');
print(r.value); // MontyInt(84)
```

**Session with plugins**

```dart
final session = ReplSession(
  plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
);
final r = await session.run(
  "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
);
print(r.value); // 'Hello World!'
```

## Documentation

- [**Installation**](docs/user/install.md) — Add to your project
- [**Overview**](docs/help.md) — API summary and quick start
- [**Architecture**](docs/architecture/overview.md) — Module structure and internals
- [**REPL Guide**](docs/user/repl.md) — Stateful interactive execution
- [**Plugins**](docs/user/plugins.md) — Template, MessageBus, Sandbox
- [**Contributor Setup**](docs/contributor/setup.md) — Build and test the library

## License

MIT License. See [LICENSE](LICENSE).
