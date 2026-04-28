# Overview

<p align="center">
  <img src="assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

[Live Demo](https://runyaga.github.io/dart_monty/) | [Documentation](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty)

Sandboxed Python interpreter for Dart and Flutter. Run Python from native, web, and mobile — one package, every platform.

## Monty is a Python *subset*

Before you write any code, know that Monty does **not** support a
chunk of regular Python. Hitting one of these features at runtime
raises a typed error, but it's much friendlier to gate your code
through `Monty.typeCheck` first.

**Not supported:**

- `class` keyword (no user-defined classes — use dicts + module-level
  functions in their place)
- Decorators (`@foo`) and `@dataclass`
- Generators (`yield`, `yield from`)
- `match` / `case`, `del`, walrus (`:=`), chained assignment
- `open()`, `eval()`, `exec()`, `locals()`, `globals()`
- `os`, `sys`, `subprocess`, `shutil`, `requests`, `urllib`, `http`
- `threading`, `multiprocessing`, `asyncio`
- Arbitrary `import` — stdlib is curated to `json`, `math`, `re`,
  `pathlib`, `datetime`, `collections`

**Pre-flight every script:**

```dart
final errors = await Monty.typeCheck(userCode);
if (errors.isNotEmpty) {
  // Reject before runtime.execute(...).
  return errors.map((e) => '${e.path}:${e.line}: ${e.message}').toList();
}
final result = await runtime.execute(userCode).result;
```

See [LLM prompt rules](tutorials/llm-prompt-rules.md) for the full
constraint list.

## Quick Start

Install both packages from GitHub (do **not** use `dart pub add` —
pub.dev has a legacy `dart_monty` 0.11.0 with a different API):

```yaml
# pubspec.yaml
dependencies:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: main
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: main
```

**One-shot execution**

```dart
final result = await Monty.exec('2 + 2');
print(result.value); // 4
```

**Stateful REPL**

```dart
final repl = MontyRepl();
await repl.feedRun('x = 42');
await repl.feedRun('def double(n): return n * 2');
final r = await repl.feedRun('double(x)');
print(r.value); // MontyInt(84)
```

**Session with extensions**

```dart
final session = MontyRuntime(
  extensions: [JinjaTemplateExtension(), MessageBusExtension()],
);
final r = await session.execute(
  "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
).result;
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
