# Documentation

`dart_monty` provides stateful restricted-Python execution and application
capabilities on top of `dart_monty_core`.

Start with [Installation](user/install.md), then choose the page for the
application behavior:

- [Runtime lifecycle and concurrency](deep-dives/bridge-concurrency.md)
- [Host functions](tutorials/host-functions-intro.md)
- [Extensions](deep-dives/extension-system.md)
- [Sandbox isolation](deep-dives/sandbox-architecture.md)
- [Filesystem and workspace policy](deep-dives/oscall-vfs.md)
- [Failure propagation](deep-dives/error-hierarchy.md)
- [Deployment](user/deployment.md)

Contributor procedures are in [Development Setup](contributor/setup.md) and
[Testing](contributor/testing.md). The public declarations are in
[`lib/dart_monty.dart`](https://github.com/runyaga/dart_monty/blob/main/lib/dart_monty.dart).
