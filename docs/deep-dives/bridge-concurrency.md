# Bridge concurrency and serialization

`MontyRuntime` runs Python on sessions checked out from a `Monty` pool. Its
execution mode determines whether Python state persists and how concurrent
calls acquire sessions.

## Shared sessions serialize execution

`MontyRuntime.start()` uses shared-session mode by default. It checks out one
session for the runtime and preserves Python globals between completed
executions. One `execute()` call runs at a time. A concurrent call returns an
`ExecutionHandle` whose `result` fails with `StateError`.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = await MontyRuntime.start();
  try {
    await runtime.execute('x = 42').result;
    final value = await runtime.execute('x + 1').result;
    print(value);
  } finally {
    await runtime.dispose();
  }
}
```

Use shared mode when later code reads state created by earlier code. A caller
that accepts concurrent requests serializes them before calling `execute()`.

```dart
import 'dart:async';

import 'package:dart_monty/dart_monty.dart';

class RuntimeQueue {
  RuntimeQueue(this.runtime);

  final MontyRuntime runtime;
  Future<void> _tail = Future<void>.value();

  Future<MontyValue> run(String code) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return () async {
      try {
        await previous.catchError((Object _) {});
        return await runtime.execute(code).result;
      } finally {
        done.complete();
      }
    }();
  }
}
```

## Fresh sessions isolate executions

Pass `sandbox: true` to `MontyRuntime.start` for one session per execution.
Each `execute()` call checks out a session, disposes its bridge and extensions
after completion, then closes the session. Python state does not persist
between calls, and independent calls can run concurrently while the pool has
available sessions.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = await MontyRuntime.start(sandbox: true);
  try {
    final values = await Future.wait([
      runtime.execute('21 * 2').result,
      runtime.execute('6 * 7').result,
    ]);
    print(values);
  } finally {
    await runtime.dispose();
  }
}
```

Provide a `Monty` pool to `MontyRuntime.start(pool: ...)` when the application
controls worker location, pool capacity, checkout timeout, and pool lifetime.
The caller closes an injected pool after disposing runtimes that use it. A
runtime-created pool closes when the runtime is disposed.

## Execution handles expose results and events

`execute()` returns immediately with an `ExecutionHandle`. Its `result`
completes with a `MontyValue` or fails with a `MontyError`. Its `events` stream
contains bridge events for that execution, and `cancel()` closes a running
session. In shared mode, the next execution checks out a fresh session after a
cancelled run.

## See also

- [Extension system](extension-system.md) describes extension attachment and
  child execution.
