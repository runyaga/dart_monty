# Upstream divergences

pydantic-monty 1.1.0 specifies Python-visible behavior. This page lists each
known dart_monty difference and its reason. An unlisted difference is a bug.

dart_monty runs Python through dart_monty_core and inherits every row in the
[dart_monty_core divergence register](https://github.com/runyaga/dart_monty_core/blob/v0.110.0-dev.4/docs/reference/upstream-divergences.md)
(C-1 to C-12). The rows below describe dart_monty additions.

The Class column distinguishes cases excluded by Dart static types, a released
API behavior paired with an additive parity API, and package checks beyond
upstream.

Each test that pins a divergent outcome names the row id in its description.

| Id | Case | Upstream 1.1.0 | dart_monty | Class | Pinned by |
|---|---|---|---|---|---|
| D-1 | A call to a function registered with the original `HostFunction` constructor that its parameters cannot bind (unknown keyword, missing or extra positional arguments) | `TypeError` with the CPython binding message | `RuntimeError: FormatException: <name>: unknown keyword argument "<kw>"` and similar. `HostFunction.parity` raises the upstream `TypeError` | LEGACY-KEPT | `test/integration/host_function_parity_test.dart` "D-1" test |
| D-2 | A host function returning a non-Monty object through the original `HostFunction` constructor | `TypeError: Cannot convert ...` | Cannot happen: the handler returns `Future<MontyValue>`. `HostFunction.parity` accepts `FutureOr<Object?>` and matches upstream | API-TYPING | none (cannot be expressed) |
| D-3 | An argument whose type differs from the `HostParamType` in the schema | No check: the host callable receives the value | `RuntimeError: FormatException: Parameter "<name>": expected <type>, got <MontyType>`, on both constructors | ADDED-CHECK | `test/integration/host_function_parity_test.dart` "D-3" test |
