# dart_monty

<p align="center">
  <img src="assets/dart_monty.jpg" alt="dart_monty" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty/actions/workflows/ci.yaml)
[![Pages](https://github.com/runyaga/dart_monty/actions/workflows/pages.yaml/badge.svg)](https://runyaga.github.io/dart_monty/)
[![codecov](https://codecov.io/gh/runyaga/dart_monty/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty)

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

Sandboxed Python interpreter for Dart and Flutter. Run Python from native, web, and mobile — one package, every platform.

> **Fork notice:** dart_monty currently builds against [`runyaga/monty`](https://github.com/runyaga/monty) (branch `runyaga/main`), a fork of [`pydantic/monty`](https://github.com/pydantic/monty). The fork carries patches required for embedding that are not yet upstream.
>
> | Patch | Upstream PR | Status |
> |-------|-------------|--------|
> | Fix partial future resolution panics in mixed `asyncio.gather()` | [pydantic/monty#251](https://github.com/pydantic/monty/pull/251) | Awaiting review |
> | `cpu: wasm32` restriction in `monty-wasm32-wasi` npm package | [runyaga/monty#4](https://github.com/runyaga/monty/issues/4) | Open issue |

## Quick Start

```bash
dart pub add dart_monty
```

**One-shot execution**

```dart
final result = await Monty.exec('2 + 2');
print(result.value); // 4
```

**Stateful REPL**

```dart
final repl = MontyRepl();
await repl.feed('x = 42');
await repl.feed('def double(n): return n * 2');
final r = await repl.feed('double(x)');
print(r.value); // MontyInt(84)
```

**Session with plugins**

```dart
final session = ReplSession(
  plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
);
final r = await session.run(
  "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
);
print(r.value); // 'Hello World!'
```

No Flutter required. It just works.

## Platform Support

| Platform | Status |
|----------|--------|
| macOS | Supported |
| Linux | Supported |
| Web (browser) | Supported |
| Windows | Planned |
| iOS | Planned |
| Android | Planned |

## Built-in Plugins

| Plugin | Functions | Description |
|--------|-----------|-------------|
| **TemplatePlugin** | `tmpl_render` | Jinja2 template rendering |
| **MessageBusPlugin** | `msg_send`, `msg_recv`, `msg_peek`, `msg_close`, `msg_stats` | In-memory named channels |
| **SandboxPlugin** | `sandbox_spawn`, `sandbox_await`, `sandbox_gather`, `sandbox_free` | Isolated child interpreters |

**SandboxPlugin works on both native (FFI) and web (WASM).** On native, each child gets a fresh interpreter. On WASM, each child gets its own Web Worker — true isolation with independent memory.

```python
# Spawn parallel workers
h1 = sandbox_spawn(code="2 ** 16")
h2 = sandbox_spawn(code="3 ** 10")
results = sandbox_gather(handles=[h1, h2])
# [{'handle': 0, 'value': 65536}, {'handle': 1, 'value': 59049}]

# Children inherit plugins — message bus for parent↔child communication
h = sandbox_spawn(code="""
msg_send(name="result", message={"answer": 42})
""")
sandbox_await(handle=h)
answer = msg_recv(name="result")  # {"answer": 42}
```

See [architecture/sandbox-architecture.md](architecture/sandbox-architecture.md) for plugin inheritance, resource limits, and grandchild support.

## OS / Filesystem

Configurable providers for filesystem, time, and environment access:

```dart
final monty = Monty(os: OsProvider());
final result = await monty.run('''
from pathlib import Path
Path("/tmp/hello.txt").write_text("hello")
Path("/tmp/hello.txt").read_text()
''');
print(result.value); // hello
```

Filesystem modes: **In-memory VFS** (ephemeral), **Read-only mount**, **Overlay** (copy-on-write over read-only base). See [docs/oscall-vfs.md](docs/oscall-vfs.md).

## Architecture

```
dart_monty (single package)
├── lib/src/platform/    Core types: MontyResult, MontyProgress, MontyValue
├── lib/src/ffi/         Native FFI backend (dart:ffi)
├── lib/src/wasm/        Web WASM backend (dart:js_interop + Worker)
├── lib/src/bridge/      Plugin dispatch, events, middleware
├── lib/src/repl/        REPL: MontyRepl, ReplSession, ReplPlatform
└── native/              Rust C API crate (.dylib/.so/.dll + .wasm)
```

Conditional imports select FFI or WASM at compile time. Pure Dart — works in CLI tools, server-side Dart, and Flutter apps.

## Documentation

- [Architecture](architecture/overview.md) — Module structure, execution paths, bridge flow
- [REPL Guide](user/repl.md) — Stateful interactive execution
- [Plugins](user/plugins.md) — Template, MessageBus, Sandbox
- [Sandbox Architecture](architecture/sandbox-architecture.md) — Child spawning, grandchildren, limits
- [Host Functions Guide](user/host-functions-intro.md) — Writing custom plugins
- [OsCall / VFS](architecture/oscall-vfs.md) — Handler hierarchy, platform defaults
- [Error Hierarchy](architecture/error-hierarchy.md) — Sealed types, propagation
- [Native Crate](internal/native-crate.md) — Handle lifecycle, FFI boundary
- [Internals](internal/internals.md) — State machine, memory contracts, testing

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, gate scripts, and CI details.

## License

MIT License. See [LICENSE](LICENSE).
