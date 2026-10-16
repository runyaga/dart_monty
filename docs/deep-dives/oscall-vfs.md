# Filesystem and workspace policy

Import memory filesystem primitives from core's public library:

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show OSAccess, MemoryFile;

final access = OSAccess(
  files: [MemoryFile('/data/input.txt', 'hello')],
  environ: {'APP_MODE': 'test'},
);
// Register on your bridge, or pass as MontyRuntime.start(os: access.call).
bridge.registerOs(access.call);
```

Core owns file operations, open modes, typed filesystem errors and environment
values. A new file requires its parent directory to exist. Clock calls may be
answered by the worker's own OS policy before reaching a callback. No host
filesystem is implicitly exposed by the memory callback.

D4a's private sandbox workspace wraps `OSAccess`; it adds dm policy without
subclassing core or exposing a new public workspace type. Its root is `/work`,
created even without input. Filesystem operations, including bare `open`, go
only to this workspace. Calls outside it synchronously decline to core's
default. Non-filesystem extension contributions remain composable.

`SandboxExtension` accepts `writeBytesLimit` and `memoryUsageLimit`. Both
omitted values default to 8,388,608 bytes. Explicit host null disables that
counter; negative values are rejected. Guest overrides only reduce a finite
host limit, or set a finite limit where the host selected null.

Accepted writes charge UTF-8 text bytes or binary bytes cumulatively; append
charges the appended payload. Deleting or truncating never refunds writes.
Retained memory is current content plus 64 bytes per file or directory entry,
including `/work`. Seeds and read-only files charge retained memory, not writes.
Rename moves content accounting and drops an overwritten destination. A failed
mutation or rejected cap changes neither the published namespace nor counters.
The memory implementation prepares a private candidate namespace and publishes
it only after core validation and cap checks succeed. This bounds logical
retained content, not temporary copies, Dart heap or interpreter memory.

The prepared Python schema is:

```python
h = sandbox_spawn(code, files={"input.txt": "/parent/input.txt"},
                  ro_files={"settings.json": "/parent/settings.json"},
                  write_bytes_limit=4096, memory_usage_limit=8192)
value = sandbox_await(h, collect={"out.txt": "/parent/result.txt"})
```

Parent paths must be absolute and child paths relative. Empty, NUL-containing,
escaping and overlapping destination paths are refused before transfer.
The originating `HostContext.os` callback is captured for collection. Nonempty
transfers without a live parent callback fail explicitly; a new mount table
cannot serve as a proxy for a suspended parent's overlay. Consumers must supply
a callback that owns the live namespace or refuses access. Native separate
session adapters are pending D4b.

Each copy or collection is independently limited to 8 MiB staged content,
4,096 entry occurrences, depth 32 below a selected root and 4,096 UTF-8 bytes
per normalized path. Aliases count again. Symlinks and their path components
are refused. Stat sizes reserve bytes before reads; growth, unknown sizes and
oversized listings fail without destination writes. These checks bound accepted
staging, not allocations inside an arbitrary consumer callback.

Transfers serialize per sandbox. A second queued collection for one workspace
is refused. Collection pre-reads all sources, using the current handler
namespace so renamed files remain visible. Parent writes then proceed in order;
a write failure may leave earlier destination writes and retains the child for
retry. An admitted collection holds a lease: disposal refuses new leases and
waits for that collection before releasing memory and its captured callback.

Native sandbox backing through `sandboxBaseDir` is pending D4b. Actual child
checkout remains the D1-8 stub until D5; D4a tests the prepared composition with
real core sessions directly. The public child state names remain until D5.
