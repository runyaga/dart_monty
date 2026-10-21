# Extension system

An extension groups Dart capabilities that attach to a `MontyRuntime`. It can
contribute host functions and OS-call handlers, initialize resources during
attachment, and release them during disposal.

The coordinator validates an extension set before Python executes.
[MontyExtension](https://github.com/runyaga/dart_monty/blob/main/lib/src/extension/extension.dart)
defines namespace, ordering, backend, and OS-prefix requirements.

An extension chooses its sandbox-child participation through
[ChildPolicy](https://github.com/runyaga/dart_monty/blob/main/lib/src/extension/extension.dart).

[AttachContext](https://github.com/runyaga/dart_monty/blob/main/lib/src/extension/attach_context.dart)
keeps attachment separate from bridge execution and disposal. Cross-extension
calls go through registered host functions instead of direct ownership of
another extension.

See [Sandbox Architecture](sandbox-architecture.md) for child ownership and
[Filesystem and workspace policy](oscall-vfs.md) for the workspace lifecycle.
[MontyExtension](https://github.com/runyaga/dart_monty/blob/main/lib/src/extension/extension.dart)
and the built-in extension declarations define the public extension surface.
