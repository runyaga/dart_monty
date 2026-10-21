# Filesystem and workspace policy

Import memory filesystem primitives from core's public library. Look at
core's `OSAccess` declaration for the memory namespace handler.

Core owns file operations, open modes, typed filesystem errors and environment
values. A new file requires its parent directory to exist. Clock calls may be
answered by the worker's own OS policy before reaching a callback. No host
filesystem is implicitly exposed by the memory callback.

The private sandbox workspace wraps `OSAccess` and adds package policy without
subclassing core or exposing a new public workspace type. Non-filesystem
extension contributions remain composable.

Use [SandboxExtension](https://github.com/runyaga/dart_monty/blob/main/lib/src/extensions/sandbox.dart)
when child execution needs a private workspace. It coordinates child lifecycle,
workspace preparation, and collection with the parent OS handler.

[Workspace](https://github.com/runyaga/dart_monty/blob/main/lib/src/workspace/workspace.dart),
[WorkspaceTransfers](https://github.com/runyaga/dart_monty/blob/main/lib/src/workspace/workspace_transfers.dart),
and
[PersistentTransfer](https://github.com/runyaga/dart_monty/blob/main/lib/src/workspace/persistent_transfer.dart)
define the workspace, transfer, and native-backing contracts. Choose memory
workspaces for browser execution. Choose native backing when the application
needs an owned workspace directory.
