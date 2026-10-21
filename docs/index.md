# Overview

<p align="center">
  <img src="assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

`dart_monty` runs restricted Python from Dart and Flutter. It builds on
`dart_monty_core` with stateful runtimes, Dart host functions, extensions,
execution events, and OS-call policy.

Use `MontyRuntime` when Python needs application capabilities or state that
persists between calls. Use core's `Monty` and `MontySession` directly for a
session feed without those features. Both choices require explicit disposal.

The package runs through a native worker on the Dart VM and through a Web
Worker on browser targets. See [Installation](user/install.md) for dependency
setup and [Deployment](user/deployment.md) for worker assets and platform
requirements.

## Documentation

- [Runtime lifecycle and concurrency](deep-dives/bridge-concurrency.md)
- [Host functions](tutorials/host-functions-intro.md)
- [Extension lifecycle](deep-dives/extension-system.md)
- [Sandbox isolation](deep-dives/sandbox-architecture.md)
- [Filesystem and workspace policy](deep-dives/oscall-vfs.md)
- [Failure propagation](deep-dives/error-hierarchy.md)
- [Contributor setup](contributor/setup.md)
- [Testing](contributor/testing.md)

The public API surface and declaration descriptions are in
[`lib/dart_monty.dart`](https://github.com/runyaga/dart_monty/blob/main/lib/dart_monty.dart).
