# OsCall / VFS Layer

When Python code uses `pathlib`, `os`, or `datetime`, the Rust interpreter
yields an `OsCall` progress event instead of performing the operation
itself. Dart receives this as a `MontyOsCall` and dispatches it through
the configured `OsProvider` hierarchy.

## Provider Hierarchy

```text
OsProvider (abstract)
  ├── FileSystemOsProvider (package:file)
  │     ├── MemoryFsOsProvider (VFS — in-memory filesystem)
  │     └── SandboxedFsProvider (chroot — restricted native FS)
  ├── OsProvider.compose() (prefix-based dispatch to child providers)
  ├── EnvOsProvider (environment variable access)
  └── TimeOsProvider (date/datetime operations)
```

- **`OsProvider`** — abstract base defining the provider contract.
- **`FileSystemOsProvider`** — handles `Path.*` calls using a
  `package:file` `FileSystem` instance.
- **`MemoryFsOsProvider`** — VFS backed by `MemoryFileSystem`.
- **`SandboxedFsProvider`** — restricts native FS access to a
  chroot directory.
- **`OsProvider.compose()`** — matches call prefixes and delegates to the
  appropriate child provider (e.g., `Path.*` to file provider, `os.*` to
  env provider).
- **`EnvOsProvider`** — handles environment variable reads/writes.
- **`TimeOsProvider`** — handles `date.*` and `datetime.*` calls.

## Platform-Conditional Default

`defaultSandboxOs()` returns a pre-wired composite `OsProvider`:

| Platform | Filesystem | Env | Time |
|----------|-----------|-----|------|
| Native | `LocalFileSystem` | yes | yes |
| Web | `MemoryFileSystem` | no | yes |

## Call Flow

```text
Python pathlib/os/datetime access
  → Rust monty yields OsCall progress
    → Dart MontyOsCall dispatched to OsProvider
      → Composite provider matches prefix
        → FileSystemOsProvider (Path.*)
        → EnvOsProvider (os.*)
        → TimeOsProvider (date.*, datetime.*)
      → Result sent back via platform.resume()
```

## Exception Contract

Providers throw `OsCallException` subclasses for domain errors (e.g., file
not found, permission denied). The bridge catches all exceptions via
`on Object` to prevent unhandled errors from crashing the interpreter
loop — non-`OsCallException` errors are wrapped and forwarded as
interpreter errors.
