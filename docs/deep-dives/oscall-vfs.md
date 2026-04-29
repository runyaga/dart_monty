# OsCall / VFS Layer

When Python code uses `pathlib`, `os`, or `datetime`, the Monty interpreter
yields an `OsCall` event. Dart intercepts this and dispatches it through a
configurable `OsCallHandler` to provide virtualized filesystem, environment,
and time access.

## Handler Composition

The functional API uses composable handlers instead of a class hierarchy.

### Handler Diagram
```mermaid
graph TD
    subgraph "Python Code"
        direction LR
        A("Path('/file.txt').read_text()") --> B{OsCall};
        C("Path('/new.txt').write_text(...)") --> B;
    end

    subgraph "OsCallHandler"
        direction LR
        B --> D{overlayFsHandler};
    end

    subgraph Filesystems
        direction TB
        D -- "Write" --> E[Scratch (MemoryFS)];
        D -- "Read" --> F[Base (ReadOnly)];
        F --> G[Real FS];
    end

    style E fill:#ccf,stroke:#333,stroke-width:2px;
```

### Core Handlers
- **`fsHandler(FileSystem)`**: Handles `Path.*` calls using a `package:file` `FileSystem`.
- **`memoryFsHandler()`**: A pre-wired VFS backed by `MemoryFileSystem`.
- **`sandboxedFsHandler({required Directory root})`**: Restricts native FS access to a root directory.
- **`readOnlyHandler(OsCallHandler)`**: A decorator that blocks write operations.
- **`overlayFsHandler({base, scratch})`**: A copy-on-write layer. Reads from `base`, writes to `scratch`.
- **`envHandler(Map<String, String>)`**: Handles `os.environ` access.
- **`timeHandler()`**: Handles `date` and `datetime` calls.
- **`composeOsHandlers(Map<String, OsCallHandler>)`**: The core dispatcher. It matches call prefixes (like `'Path.'`) and delegates to the appropriate child handler.

## Filesystem Modes

| Mode | Handler | Use Case |
|---|---|---|
| **Default** | `defaultOsHandler()` | Platform-appropriate defaults (native FS on desktop, memory FS on web). |
| **In-memory** | `memoryFsHandler()` | Ephemeral VFS, works on all platforms. |
| **Read-only** | `readOnlyHandler(...)` | Wraps any handler, blocks writes. |
| **Sandboxed** | `sandboxedFsHandler(...)` | Chroots to a directory on the native filesystem. |
| **Overlay** | `overlayFsHandler(...)` | Agent workloads that need to read the real filesystem but write to an ephemeral layer. |

### Examples

```dart
// Default handler provides a sandboxed native FS on desktop/mobile.
// Concretely:
//   - Reads/writes outside the scratch / worktree subtree → EPERM
//     (PathAccessException).
//   - Reads of credential-bearing dirs (~/.ssh, ~/.aws, ~/.claude,
//     and the harness's own .env) → EPERM even when the file
//     doesn't exist.
//   - Public system paths (/etc/hosts, /usr/share/zoneinfo) →
//     readable. Calibration data, not a deny target.
//   - Network calls have no built-in primitive — you must register
//     a host function to expose any network at all.
// Set DART_MONTY_OS_PROFILE=strict to refuse start when the
// platform sandbox-exec/bwrap binary is missing.
final session = MontyRuntime(os: defaultOsHandler());

// In-memory VFS with prepopulated files
final fs = MemoryFileSystem();
fs.file('/data/input.csv').writeAsStringSync('a,b,c');
final session = MontyRuntime(osHandlers: {
  'Path.': fsHandler(fs),
});

// Read-only wrapper around the local filesystem
final session = MontyRuntime(osHandlers: {
  'Path.': readOnlyHandler(fsHandler(const LocalFileSystem())),
});

// Overlay for agent workloads
final session = MontyRuntime(osHandlers: {
  'Path.': overlayFsHandler(
    base: readOnlyHandler(fsHandler(const LocalFileSystem())),
    scratch: memoryFsHandler(),
  ),
});
```
