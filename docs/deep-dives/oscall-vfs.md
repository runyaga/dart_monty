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

## Provider Hierarchy

```text
OsCallHandler (abstract)
  ├── FsProvider (package:file)
  │     ├── MemoryFsProvider (VFS — in-memory filesystem)
  │     └── SandboxedFsProvider (chroot — restricted native FS)
  ├── OsCallHandler.compose() (prefix-based dispatch to child providers)
  ├── EnvOsCallHandler (environment variable access)
  └── TimeOsCallHandler (date/datetime operations)
```

- **`OsCallHandler`** — abstract base defining the provider contract.
- **`FsProvider`** — handles `Path.*` calls using a
  `package:file` `FileSystem` instance.
- **`MemoryFsProvider`** — VFS backed by `MemoryFileSystem`.
- **`SandboxedFsProvider`** — restricts native FS access to a
  chroot directory.
- **`OsCallHandler.compose()`** — matches call prefixes and delegates to the
  appropriate child provider (e.g., `Path.*` to file provider, `os.*` to
  env provider).
- **`EnvOsCallHandler`** — handles environment variable reads/writes.
- **`TimeOsCallHandler`** — handles `date.*` and `datetime.*` calls.

## Filesystem Modes

| Mode | Class | Use case |
|------|-------|----------|
| **Default** | `OsCallHandler()` | Platform-appropriate defaults (native FS on desktop, memory FS on web) |
| **In-memory** | `MemoryFsProvider` | Ephemeral VFS, works on all platforms |
| **Read-only** | `ReadOnlyFsProvider` | Wraps any provider, blocks writes |
| **Sandboxed** | `SandboxedFsProvider` | Chroot to a directory on native FS |
| **Overlay** | `OverlayFsProvider` | Copy-on-write: reads from base, writes to scratch |

### Examples

```dart
// Basic filesystem operations
final monty = Monty(os: OsCallHandler());
final result = await monty.run('''
from pathlib import Path
Path("/tmp/hello.txt").write_text("hello")
Path("/tmp/hello.txt").read_text()
''');
print(result.value); // hello

// Default — platform-appropriate (native FS on desktop, memory on web)
final monty = Monty(os: OsCallHandler());

// In-memory VFS
final vfs = MemoryFsProvider();
vfs.writeFile('/data/input.csv', data);
final monty = Monty(os: OsCallHandler.compose({
  'Path.': vfs,
  'date.': TimeOsCallHandler(),
  'datetime.': TimeOsCallHandler(),
}));

// Read-only wrapper
final monty = Monty(os: OsCallHandler.compose({
  'Path.': ReadOnlyFsProvider(FsProvider(const LocalFileSystem())),
}));

// Overlay (agent workloads)
final scratch = MemoryFsProvider();
final monty = Monty(os: OsCallHandler.compose({
  'Path.': OverlayFsProvider(
    base: SandboxedFsProvider(root: projectDir),
    scratch: scratch,
  ),
}));
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
