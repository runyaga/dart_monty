# Core and dart_monty ownership

`dart_monty_core` owns sessions, worker transport, Python values, resource
limits, host mounts, memory files, and OS-call defaults. Applications import
additional core primitives from its public library. `dart_monty` imports no
core implementation libraries.

`dart_monty` owns bridge events, host-function dispatch, extensions, runtime
state, and private sandbox workspace composition. Workspace code uses core's
public `OSAccess`, `MemoryFile`, snapshot, and mount operations.

`OSAccess` is a memory namespace. `MountDir` is native host backing. Native
backing stays behind conditional imports so browser builds do not load native
helpers.

The facade in `lib/dart_monty.dart` is the supported package surface.
[dart_monty.dart](https://github.com/runyaga/dart_monty/blob/main/lib/dart_monty.dart)
exports the core and high-level declarations.

See [Filesystem and workspace policy](../deep-dives/oscall-vfs.md) for transfer,
accounting, and disposal guarantees.
