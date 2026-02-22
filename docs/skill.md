# Monty API — Dart

Sandboxed Python interpreter for Dart/Flutter (federated plugin).

## Types

| Type | Fields |
|------|--------|
| `MontyResult` | `.value`, `.error`, `.usage` |
| `MontyException` | `.message`, `.lineNumber`, `.columnNumber` |
| `MontyLimits` | `.timeoutMs`, `.memoryBytes`, `.stackDepth` |
| `MontyResourceUsage` | `.memoryBytesUsed`, `.timeElapsedMs` |
| `MontyProgress` | sealed: `MontyPending`, `MontyComplete` |
| `MontyPending` | `.functionName`, `.arguments` |
| `MontyComplete` | `.result` (a `MontyResult`) |

## Run

```dart
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

final monty = MontyFfi(bindings: NativeBindingsFfi());
final result = await monty.run('2 ** 100');
// result.value  -> 1267650600228229401496703205376
// result.usage.memoryBytesUsed, .timeElapsedMs, .stackDepthUsed
await monty.dispose();
```

Multi-line:

```dart
final result = await monty.run('''
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
fib(30)
''');
// result.value -> 832040
```

## Limits

All fields optional. Omitted = unconstrained. Exceeding throws
`MontyException`.

```dart
try {
  await monty.run(
    'while True: pass',
    limits: MontyLimits(
      timeoutMs: 100,
      memoryBytes: 10 * 1024 * 1024,
      stackDepth: 50,
    ),
  );
} on MontyException catch (e) {
  print(e.message); // timeout exceeded
}
```

## Iterative Execution

`start()` declares external functions. Python pauses when it calls
one, returning `MontyPending`. `resume(returnValue)` continues.

```dart
final monty = MontyFfi(bindings: NativeBindingsFfi());
var progress = await monty.start(
  '''
url = "https://example.com"
html = fetch(url)
len(html)
''',
  externalFunctions: ['fetch'],
);

while (progress is MontyPending) {
  final url = progress.arguments.first.toString();
  final response = await http.get(Uri.parse(url));
  progress = await monty.resume(response.body);
}

final complete = progress as MontyComplete;
print(complete.result.value);
await monty.dispose();
```

Pattern match:

```dart
switch (progress) {
  case MontyComplete(:final result):
    print(result.value);
  case MontyPending(:final functionName, :final arguments):
    print('$functionName($arguments)');
}
```

## Error Injection

`resumeWithError(message)` raises a Python `Exception` in the
paused interpreter.

```dart
final monty = MontyFfi(bindings: NativeBindingsFfi());
var progress = await monty.start(
  '''
try:
    data = fetch("https://httpstat.us/500")
except Exception as e:
    result = f"caught: {e}"
result
''',
  externalFunctions: ['fetch'],
);

while (progress is MontyPending) {
  // Inject an error instead of a return value
  progress = await monty.resumeWithError('HTTP 500');
}

final complete = progress as MontyComplete;
print(complete.result.value); // "caught: HTTP 500"
await monty.dispose();
```

## Cooperative Multitasking

Any external function name works. Convention: `yield_state`.
Python pauses on each call; Dart reads args, updates UI, resumes.

```dart
final monty = MontyFfi(bindings: NativeBindingsFfi());
var progress = await monty.start(
  '''
arr = [5, 3, 1, 4, 2]
n = len(arr)
i = 0
while i < n:
    j = 0
    while j < n - i - 1:
        yield_state(arr, j, j + 1, "compare")
        if arr[j] > arr[j + 1]:
            tmp = arr[j]
            arr[j] = arr[j + 1]
            arr[j + 1] = tmp
            yield_state(arr, j, j + 1, "swap")
        j = j + 1
    i = i + 1
yield_state(arr, -1, -1, "done")
arr
''',
  externalFunctions: ['yield_state'],
);

while (progress is MontyPending) {
  final args = progress.arguments;
  final array = (args[0]! as List).cast<int>();
  final i = args[1]! as int;
  final j = args[2]! as int;
  final action = args[3]! as String;
  setState(() { /* update UI with array, i, j, action */ });
  await Future<void>.delayed(const Duration(milliseconds: 50));
  progress = await monty.resume(null);
}
await monty.dispose();
```

## Error Handling

Python errors throw `MontyException`. They never return silently
inside `MontyResult`.

```dart
final monty = MontyFfi(bindings: NativeBindingsFfi());
try {
  await monty.run('items = [1, 2, 3]\nitems[10]');
} on MontyException catch (e) {
  print(e.message);      // "list index out of range"
  print(e.lineNumber);   // 2
  print(e.columnNumber); // nullable
  print(e.sourceCode);   // nullable
} finally {
  await monty.dispose();
}
```

## State Machine

| State | Allowed methods |
|-------|----------------|
| **idle** | `run()`, `start()`, `restore()`, `dispose()` |
| **active** | `resume()`, `resumeWithError()`, `snapshot()`, `dispose()` |
| **disposed** | none (throws `StateError`) |

- `start()`: idle -> active
- `resume()`/`resumeWithError()` + `MontyComplete`: active -> idle
- `resume()`/`resumeWithError()` + `MontyPending`: stays active
- `dispose()`: any -> disposed (no-op if already disposed)
- Wrong-state call throws `StateError`

## Platform Backends

### Native — `MontyFfi`

```dart
import 'package:dart_monty_ffi/dart_monty_ffi.dart';

final monty = MontyFfi(bindings: NativeBindingsFfi());
// ready to use immediately
```

### Web — `MontyWasm`

```dart
import 'package:dart_monty_wasm/dart_monty_wasm.dart';

final monty = MontyWasm(bindings: WasmBindingsJs());
await monty.initialize(); // optional, auto-called on first use
```

### Register globally

```dart
MontyPlatform.instance = monty; // then use MontyPlatform.instance
```

## Constraints

- `inputs` parameter: throws `UnsupportedError` if non-empty
- `initialize()` (WASM only): idempotent, auto-called by `run()`/`start()`
- Snapshots on web: rely on Node.js `Buffer`, may fail in browsers
- WASM `MontyResourceUsage`: synthetic zeros (no `ResourceTracker`)
- One execution at a time: `run()`/`start()` while active throws `StateError`
