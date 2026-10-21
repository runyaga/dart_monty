# dart_monty

<p align="center">
  <img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

`dart_monty` runs restricted Python from Dart and Flutter on native and web
platforms. It adds stateful runtimes, Dart host functions, extensions, event
streams, and OS-call policy to the pool and session primitives supplied by
`dart_monty_core`.

## Installation

The package and its core dependency are released from matching Git tags. Add
the package and override core in the application `pubspec.yaml`:

```yaml
dependencies:
  dart_monty:
    git:
      url: https://github.com/runyaga/dart_monty.git
      ref: v0.110.0-dev.4

dependency_overrides:
  dart_monty_core:
    git:
      url: https://github.com/runyaga/dart_monty_core.git
      ref: v0.110.0-dev.4
```

See [Installation](docs/user/install.md) for direct core imports and local
worktree dependencies.

## Quick start

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = await MontyRuntime.start();
  try {
    await runtime.execute('x = 41').result;
    final value = await runtime.execute('x + 1').result;
    print(value.dartValue); // 42
  } finally {
    await runtime.dispose();
  }
}
```

See [Choosing an API](docs/user/api-reference.md) for the runtime and direct
session tradeoffs.

## Platform support

The Dart VM and Flutter native targets use core's native worker. Browser
targets use its Web Worker and WASM assets. Web deployments require the
worker assets and cross-origin isolation headers. Native applications that use
`MountDir` or self-contained executables must opt in to core's worker build.
See [Deployment and Bundling](docs/user/deployment.md) for those constraints.

## Documentation

- [Stateful and concurrent execution](docs/deep-dives/bridge-concurrency.md)
- [Host functions](docs/tutorials/host-functions-intro.md)
- [Extensions](docs/deep-dives/extension-system.md)
- [Sandbox lifecycle and isolation](docs/deep-dives/sandbox-architecture.md)
- [Filesystem and workspace policy](docs/deep-dives/oscall-vfs.md)
- [Failure propagation](docs/deep-dives/error-hierarchy.md)
- [Testing](docs/contributor/testing.md)

The public declarations are listed in
[`lib/dart_monty.dart`](lib/dart_monty.dart).

## License

The package uses the [MIT License](LICENSE).
