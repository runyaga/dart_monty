# Upstream divergences

pydantic-monty 1.2.0 specifies Python-visible behavior. This page lists each
known dart_monty difference and its reason. An unlisted difference is a bug.

dart_monty runs Python through dart_monty_core and inherits every row in the
[dart_monty_core divergence register](https://github.com/runyaga/dart_monty_core/blob/bcfbc232ece6436c3e68ec7edfca7c1cad6a32be/docs/reference/upstream-divergences.md)
including its module rules. Core is pinned to commit `bcfbc23` on branch
0.120, not a release. The rows below describe dart_monty additions.

The Class column distinguishes cases excluded by Dart static types, a released
API behavior paired with an additive parity API, and package checks beyond
upstream.

Each test that pins a divergent outcome names the row id in its description.

| Id | Case | Upstream 1.2.0 | dart_monty | Class | Pinned by |
|---|---|---|---|---|---|
| D-1 | A call to a function registered with the original `HostFunction` constructor that its parameters cannot bind (unknown keyword, missing or extra positional arguments) | `TypeError` with the CPython binding message | `RuntimeError: FormatException: <name>: unknown keyword argument "<kw>"` and similar. `HostFunction.parity` raises the upstream `TypeError` | LEGACY-KEPT | `test/integration/host_function_parity_test.dart` "D-1" test |
| D-2 | A host function returning a non-Monty object through the original `HostFunction` constructor | `TypeError: Cannot convert ...` | Cannot happen: the handler returns `Future<MontyValue>`. `HostFunction.parity` accepts `FutureOr<Object?>` and matches upstream | API-TYPING | none (cannot be expressed) |
| D-3 | An argument whose type differs from the `HostParamType` in the schema | No check: the host callable receives the value | `RuntimeError: FormatException: Parameter "<name>": expected <type>, got <MontyType>`, on both constructors | ADDED-CHECK | `test/integration/host_function_parity_test.dart` "D-3" test |

## Upstream 1.2.0 behavior

These outcomes match upstream 1.2.0; they are not additional divergences.

| Operation | Observed behavior | Pinned by |
|---|---|---|
| `Path.rename('moved')` | Returns the target path, a relative `PosixPath('moved')`; the source disappears and the target keeps its contents. | [native_workspace_driver_test.dart:35-56](https://github.com/runyaga/dart_monty/blob/port-0.120/test/integration/native_workspace_driver_test.dart#L35-L56) |
| Open-file iteration | `iter(handle) is handle`; `next`, `readline`, and iteration share the read position. At EOF, `next(handle, default)` returns the default and `next(handle)` raises `StopIteration`. | [ffi_file_io_test.dart:46-77](https://github.com/runyaga/dart_monty/blob/port-0.120/test/integration/ffi_file_io_test.dart#L46-L77) |
| Type-check rejection | A feed rejected with `MontyTypingError` keeps its requested cwd. The next workspace feed with `cwd: null` observes `/work/nested`; omitting `cwd` selects the workspace default `/work`. | [monty_type_check_test.dart:48-70](https://github.com/runyaga/dart_monty/blob/port-0.120/test/integration/monty_type_check_test.dart#L48-L70) |
