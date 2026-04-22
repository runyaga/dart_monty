# OsCall / VFS Layer

> **How this relates to host functions and extensions:**
> dart_monty has two interception layers that work together.
> **OsCallHandler** provides transparent OS-level interception (filesystem, env,
> time) -- Python does not know it is being intercepted.
> **HostFunction / MontyExtension** provides explicit named tools that Python
> calls by name -- LLMs know about these and generate code against them.
> Both are registered on `MontyBridge`: `registerOs()` for the OS side,
> `register()` / `ExtensionCoordinator` for the tool side.
> See [../architecture/overview.md](../architecture/overview.md) for the full tool-calling flow.

When Python code uses `pathlib`, `os`, or `datetime`, the Rust interpreter
yields an `OsCall` progress event instead of performing the operation
itself. Dart receives this as a `MontyOsCall` and dispatches it through
the configured `OsCallHandler` hierarchy.

## Handler Composition

```text
OsCallHandler (typedef: (operation, args, kwargs) → Future<Object?>)
  ├── fsHandler(FileSystem)         (generic Path.* handler)
  ├── memoryFsHandler()             (ephemeral in-memory VFS)
  ├── sandboxedFsHandler(root)      (restricted native FS)
  ├── readOnlyHandler(child)        (blocks write operations)
  ├── overlayFsHandler(base, scratch) (copy-on-write overlay)
  ├── envHandler(Map<String, String>) (os.* environment handler)
  ├── timeHandler()                 (date.* / datetime.* handler)
  └── composeOsHandlers({prefix: handler}) (prefix-based dispatch)
```

- **`fsHandler(fs)`** — handles `Path.*` calls using a `package:file` `FileSystem`.
- **`memoryFsHandler()`** — VFS backed by `MemoryFileSystem`.
- **`sandboxedFsHandler(root)`** — restricts native FS access to a root directory.
- **`readOnlyHandler(child)`** — wraps any handler and blocks write operations.
- **`overlayFsHandler(base, scratch)`** — reads from base, writes to scratch.
- **`envHandler(env)`** — handles `os.environ` and related calls.
- **`timeHandler()`** — handles `date` and `datetime` calls.
- **`composeOsHandlers()`** — matches call prefixes and delegates to the appropriate child handler.

## Filesystem Modes

| Mode | Handler | Use case |
|------|-------|----------|
| **Default** | `defaultOsHandler()` | Platform-appropriate defaults (native FS on desktop, memory FS on web) |
| **In-memory** | `memoryFsHandler()` | Ephemeral VFS, works on all platforms |
| **Read-only** | `readOnlyHandler()` | Wraps any handler, blocks writes |
| **Sandboxed** | `sandboxedFsHandler()` | Chroot to a directory on native FS |
| **Overlay** | `overlayFsHandler()` | Copy-on-write: reads from base, writes to scratch |

### Examples

```dart
// Basic filesystem operations
final session = MontyRuntime(os: defaultOsHandler());
final handle = session.execute('''
from pathlib import Path
Path("/tmp/hello.txt").write_text("hello")
print(Path("/tmp/hello.txt").read_text())
''');
await handle.result;

// In-memory VFS with prepopulated files
final fs = MemoryFileSystem();
fs.file('/data/input.csv').writeAsStringSync(csvContent);

final session = MontyRuntime(osHandlers: {
  'Path.': fsHandler(fs),
  'date.': timeHandler(),
  'datetime.': timeHandler(),
});

// Read-only wrapper
final session = MontyRuntime(osHandlers: {
  'Path.': readOnlyHandler(fsHandler(const LocalFileSystem())),
});

// Overlay (agent workloads)
final scratch = memoryFsHandler();
final session = MontyRuntime(osHandlers: {
  'Path.': overlayFsHandler(
    base: sandboxedFsHandler(root: projectDir),
    scratch: scratch,
  ),
});
```

## Platform-Conditional Default

`OsCallHandler()` returns a pre-wired composite provider:

| Platform | Filesystem | Env | Time |
|----------|-----------|-----|------|
| Native | `LocalFileSystem` | yes | yes |
| Web | `MemoryFileSystem` | no | yes |

## Call Flow

```text
Python pathlib/os/datetime access
  → Rust monty yields OsCall progress
    → Dart MontyOsCall dispatched to OsCallHandler
      → Composite provider matches prefix
        → FsProvider (Path.*)
        → EnvOsCallHandler (os.*)
        → TimeOsCallHandler (date.*, datetime.*)
      → Result sent back via platform.resume()
```

## Exception Contract

Providers throw `OsCallException` subclasses for domain errors (e.g., file
not found, permission denied). The bridge catches all exceptions via
`on Object` to prevent unhandled errors from crashing the interpreter
loop — non-`OsCallException` errors are wrapped and forwarded as
interpreter errors.
