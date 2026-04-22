# Overview

<p align="center">
  <img src="assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

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

**Session with extensions**

```dart
final session = MontyRuntime(
  extensions: [JinjaTemplateExtension(), MessageBusExtension()],
);
final r = await session.run(
  "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
);
print(r.value); // 'Hello World!'
```

## Documentation

- [**Installation**](user/install.md) — Add to your project
- [**Architecture**](architecture/overview.md) — Module structure and internals
- [**REPL Guide**](user/repl.md) — Stateful interactive execution
- [**Extensions**](user/extensions.md) — Template, MessageBus, Sandbox
- [**Tutorials**](tutorials/host-functions-intro.md) — Bridge functions and LLM rules
- [**Testing**](contributor/testing.md) — Run tests and quality gates
- [**Contributor Setup**](contributor/setup.md) — Build and test the library
