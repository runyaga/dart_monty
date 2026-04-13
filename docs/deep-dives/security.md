# Security & Resource Guardrails

`dart_monty` is built from the ground up to execute untrusted code safely. It uses a multi-layered defense strategy to protect the host system from malicious or poorly-written Python scripts.

## The Air Gap Architecture

The core of `dart_monty`'s security is the strict separation between the Python interpreter and the host environment.

1. **Crate-Level Stripping**: The underlying `monty` Rust crate does not include standard Python modules that interact with the OS (like `os`, `sys`, `subprocess`, or `socket`).
2. **No Native Access**: Python code cannot access memory outside its own heap. It has no access to the Dart VM or the host's native pointers.
3. **Bridge-Only Communication**: The only way for Python to interact with the outside world is through host functions explicitly registered by you on the `MontyBridge`.

## Resource Quotas

To prevent Denial of Service (DoS) attacks or accidental resource exhaustion, `dart_monty` enforces hard limits on the interpreter.

### 1. Hard Memory Limits

The interpreter's memory is capped at the native level.

- **FFI**: Rust uses a custom allocator to monitor every byte used by Python. If the script exceeds the limit (e.g., 16MB), the interpreter is instantly killed with a `MontyError`.
- **WASM**: Each session runs in an isolated Web Worker with its own memory space, ensuring a runaway script cannot crash your main UI thread.

### 2. Stack Depth Guards

To prevent stack overflow attacks (infinite recursion), `dart_monty` limits the depth of the Python call stack. This ensures that even deeply nested loops cannot consume host thread resources.

### 3. Execution Timeouts

Every `execute()` call can be wrapped in a watchdog timer. If the Python script enters an infinite loop (`while True: pass`), the host will terminate the interpreter after the timeout expires.

```dart
// Setting global limits
final limits = MontyLimits(
  memoryBytes: 16 * 1024 * 1024, // 16MB
  timeoutMs: 5000,               // 5 seconds
);
```

## VFS Sandboxing (`OsProvider`)

Python scripts often expect to work with a filesystem. `dart_monty` virtualizes this surface using the `OsProvider` system.

- **Isolation**: By default, Python sees an empty or restricted filesystem.
- **Memory-Backed VFS**: You can provide a `MemoryFsProvider` that exists only in RAM. Python can read and write files, but they never touch your real hard drive and vanish when the session is disposed.
- **Path Remapping**: You can map Python's `/home/user` to a specific, safe subdirectory on the host, preventing "Path Traversal" attacks.

## Call Attribution and Policy

As detailed in the [Grounding Deep Dive](grounding.md), all "Out-of-Sandbox" calls are attributed to a role. This ensures that:

- Infrastructure calls (like state persistence) bypass user-defined limits.
- Tool calls (like database queries) are subject to rate limiting, authentication, and output validation.
