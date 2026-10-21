# Runtime concurrency and state

`MontyRuntime` runs Python on sessions from a `Monty` pool. Choose shared mode
when later code must read state created by earlier code. Choose fresh-session
mode when calls require isolated globals or independent scheduling.

## Shared mode requires caller serialization

The runtime retains one session in shared mode. The application must serialize
requests when several callers share that runtime. A small queue can preserve
request order without moving that policy into the runtime:

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

## Fresh mode trades state for concurrency

Fresh mode isolates Python globals while pool capacity permits independent
calls. Pool capacity must also cover nested work started by host functions or
sandbox children.

[MontyRuntime](https://github.com/runyaga/dart_monty/blob/main/lib/src/runtime/runtime.dart)
and
[ExecutionHandle](https://github.com/runyaga/dart_monty/blob/main/lib/src/runtime/execution_handle.dart)
define lifecycle contracts. See [Extension system](extension-system.md) for
attachment and child-execution ownership.
