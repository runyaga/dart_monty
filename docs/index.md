# Overview

<p align="center">
  <img src="assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

**dart_monty v0.110.0-dev.3** &middot; built against `dart_monty_core` `d3bb80fc3bfb05d5f6707174f1cae3970671f69f`

[Live Demo](https://runyaga.github.io/dart_monty/) | [Documentation](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty)

`dart_monty` provides sandboxed Python execution for Dart and Flutter.

## Quick Start

Install the packages from their matching Git tags. See
[Installation](user/install.md) for the dependency entries.

**One-shot execution**

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final value = await Monty.withPool(
    (pool) => pool.withSession((session) => session.feedRun('2 + 2')),
  );
  print(value.dartValue); // 4
}
```

**Stateful session**

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  await Monty.withPool((pool) async {
    final session = await pool.checkout();
    try {
      await session.feedRun('x = 42');
      final value = await session.feedRun('x * 2');
      print(value.dartValue); // 84
    } finally {
      await session.close();
    }
  });
}
```

**Runtime with extensions**

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = await MontyRuntime.start(
    extensions: [EventLoopExtension()],
  );
  try {
    final value = await runtime.execute('1 + 1').result;
    print(value.dartValue); // 2
  } finally {
    await runtime.dispose();
  }
}
```

## Documentation

- [**Installation**](user/install.md): Add the packages to a project.
- [**Architecture**](architecture/overview.md): Module structure and internals.
- [**REPL Guide**](user/repl.md): Stateful interactive execution.
- [**Extensions**](user/extensions.md): Event loop and sandbox extensions.
- [**Tutorials**](tutorials/host-functions-intro.md): Host functions and LLM rules.
- [**Testing**](contributor/testing.md): Test suites and quality gates.
- [**Contributor Setup**](contributor/setup.md): Build and test the library.
