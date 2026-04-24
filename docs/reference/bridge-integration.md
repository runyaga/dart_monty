# Bridge Integration — Dart + JS + WASM Worker

How Python code runs inside a browser tab: three layers, zero servers.

## Three-Layer Architecture

```text
 Dart (main thread)           JS Bridge (main thread)         WASM Worker
 ──────────────────           ──────────────────────          ────────────
 @JS() interop bindings  ──>  window.DartMontyBridge    ──>  Web Worker
 dart:js_interop              postMessage + promise map       @pydantic/monty WASM
                         <──                             <──
                              resolve pending promise         postMessage response
```

**Dart** calls `@JS()`-annotated external functions that resolve to methods on
`window.DartMontyBridge`. The **JS bridge** serializes each call into a
`postMessage` to the Web Worker, tracked by a unique integer ID. The **Worker**
runs the Monty WASM interpreter and posts results back. The bridge resolves the
matching promise, which Dart awaits via `.toDart`.

## Layer 1: Dart JS Interop Bindings

Dart declares external functions using `dart:js_interop` annotations that map
directly to `window.DartMontyBridge.*` methods:

```dart
@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.start')
external JSPromise<JSString> _bridgeStart(
  JSString code, [JSString? extFnsJson]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _bridgeResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _bridgeResumeWithError(JSString errorJson);

@JS('DartMontyBridge.snapshot')
external JSPromise<JSString> _bridgeSnapshot();

@JS('DartMontyBridge.restore')
external JSPromise<JSString> _bridgeRestore(JSString dataBase64);
```

Every function returns `JSPromise<JSString>`. Dart converts to a native Future
with `.toDart`, then parses the JSON string result:

```dart
final resultJson = (await _bridgeStart(code.toJS, extFnsJson.toJS).toDart).toDart;
final result = jsonDecode(resultJson) as Map<String, dynamic>;
```

The `dart_monty_wasm` package wraps this pattern in `WasmBindingsJs`
(`packages/dart_monty_wasm/lib/src/wasm_bindings_js.dart`), which adapts
all calls to the `WasmBindings` abstract interface.

## Layer 2: JS Bridge (`dart_monty_core_bridge.js`)

The bridge is a self-contained IIFE that creates the Worker and manages
request/response correlation:

```javascript
var worker = null;
var nextId = 1;
var pending = new Map();  // id -> { resolve, reject }

function callWorker(msg) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    worker.postMessage({ ...msg, id });
  });
}
```

Every bridge method follows the same pattern:

1. Guard: if `!worker`, return an error JSON string
2. Call `callWorker(msg)` with a typed message
3. Serialize the response as JSON string

The Worker's `onmessage` handler resolves the matching pending promise:

```javascript
worker.onmessage = (e) => {
  const msg = e.data;
  if (msg.type === "ready") { resolve(true); return; }
  if (msg.id && pending.has(msg.id)) {
    const { resolve: res } = pending.get(msg.id);
    pending.delete(msg.id);
    res(msg);
  }
};
```

### Bridge API Surface

| Method | Worker message type | Purpose |
|--------|-------------------|---------|
| `init()` | (creates Worker) | Initialize WASM runtime |
| `run(code, limitsJson, scriptName)` | `run` | One-shot execution |
| `start(code, extFnsJson, limitsJson, scriptName)` | `start` | Begin iterative execution |
| `resume(valueJson)` | `resume` | Continue with host function return value |
| `resumeWithError(errorJson)` | `resumeWithError` | Continue with error |
| `snapshot()` | `snapshot` | Capture interpreter state (base64) |
| `restore(dataBase64)` | `restore` | Restore interpreter from snapshot |
| `discover()` | (synchronous) | Check if Worker is loaded |
| `dispose()` | `dispose` | Terminate Worker |

## Layer 3: WASM Worker

The Worker loads `@pydantic/monty-wasm32-wasi` and handles messages
dispatched from the bridge. Key state:

- `monty` — the Monty interpreter instance
- `activeSnapshot` — set when execution pauses (pending), used for resume

On `start`, the Worker compiles and runs the code. If the code calls an
external function, execution pauses and the Worker posts a `pending` message
back with the function name and arguments. On `resume`, the Worker feeds the
return value back into the snapshot and continues.

### Why a Worker?

Chrome's synchronous `WebAssembly.compile()` limit is 8 MB. The Monty WASM
module exceeds this. Inside a Worker, `WebAssembly.compileStreaming` works
asynchronously without this limit.

## The Execution Loop

The core pattern for running Python that calls host functions:

```text
Dart                    JS Bridge              Worker
 │                        │                      │
 │ _bridgeStart(code, fns)│                      │
 │───────────────────────>│  postMessage(start)  │
 │                        │─────────────────────>│
 │                        │                      │ ── Python runs ──
 │                        │                      │ ── hits dom_create() ──
 │                        │  postMessage(pending)│
 │                        │<─────────────────────│
 │  { state: "pending",   │                      │
 │    functionName: ...    │                      │
 │    args: [...] }        │                      │
 │<───────────────────────│                      │
 │                        │                      │
 │ (Dart handles the call)│                      │
 │                        │                      │
 │ _bridgeResume(value)   │                      │
 │───────────────────────>│  postMessage(resume) │
 │                        │─────────────────────>│
 │                        │                      │ ── Python resumes ──
 │                        │                      │ ── hits dom_text() ──
 │                        │  postMessage(pending)│
 │                        │<─────────────────────│
 │                        │                      │
 │ (repeat until complete)│                      │
 │                        │                      │
 │  { state: "complete",  │                      │
 │    value: ..., ok: true}│                     │
 │<───────────────────────│                      │
```

In Dart, this loop is implemented as:

```dart
Future<Map<String, dynamic>> _runWithHostFunctions(String code) async {
  final extFnsJson = jsonEncode(_hostFunctions);
  var result = _parse(
    (await _bridgeStart(code.toJS, extFnsJson.toJS).toDart).toDart,
  );

  while (result['state'] == 'pending') {
    final fnName = result['functionName'] as String;
    final fnArgs = (result['args'] as List<dynamic>?) ?? [];

    try {
      final value = await _dispatch(fnName, fnArgs);
      result = _parse(
        (await _bridgeResume(jsonEncode(value).toJS).toDart).toDart,
      );
    } on Exception catch (e) {
      result = _parse(
        (await _bridgeResumeWithError(
          jsonEncode(e.toString()).toJS).toDart).toDart,
      );
    }
  }
  return result;
}
```

## Host Function Implementation Patterns

### Pattern 1: Synchronous — return a value immediately

```dart
case 'dom_create':
  final tag = args.isNotEmpty ? args[0] as String : 'div';
  final el = document.createElement(tag);
  return _store(el);  // returns int handle

case 'now':
  return DateTime.now().toIso8601String();

case 'json_dumps':
  return jsonEncode(args[0]);
```

These compute a result synchronously and return it. The dispatch function
wraps the return value in `jsonEncode()` and feeds it to `_bridgeResume()`.

### Pattern 2: Blocking — await a Future, Python suspends

```dart
case 'dom_on_click':
  final h = args[0] as int;
  final el = _get(h);
  if (el == null) return null;
  final completer = Completer<String>();
  el.addEventListener('click', (Event e) {
    if (!completer.isCompleted) completer.complete('clicked');
  }.toJS);
  return await completer.future;  // Python blocks here
```

The dispatch function is `async` — it can `await` Dart Futures. Python
execution is already suspended (the Worker is waiting). When the click
fires, the Completer resolves, the dispatch function returns, and
`_bridgeResume()` continues Python.

### Pattern 3: Multi-button wait — `dom_await_click_any`

```dart
case 'dom_await_click_any':
  final handles = (args[0] as List<dynamic>).cast<int>();
  final completer = Completer<int>();
  for (final h in handles) {
    final el = _get(h);
    if (el != null) {
      el.addEventListener('click', (Event e) {
        if (!completer.isCompleted) completer.complete(h);
      }.toJS);
    }
  }
  return await completer.future;  // returns which handle was clicked
```

This enables `while True` event loops in Python — the script blocks on
`dom_await_click_any([btn1, btn2, btn3])`, gets back which button was
clicked, dispatches the action, and loops.

### Pattern 4: Browser API — file upload

```dart
case 'upload_file':
  final input = document.createElement('input') as HTMLInputElement;
  input.type = 'file';
  final completer = Completer<String?>();
  input.addEventListener('change', (Event e) {
    final file = input.files!.item(0)!;
    final reader = FileReader();
    reader.addEventListener('load', (Event ev) {
      completer.complete((reader.result as JSString?)?.toDart ?? '');
    }.toJS);
    reader.readAsText(file);
  }.toJS);
  input.click();
  return await completer.future;
```

Python calls `upload_file()` and blocks. Dart opens a file picker, reads
the selected file, and returns its text content. Python resumes with the
file data as a string.

## Opaque Handle System

DOM elements cannot cross the WASM boundary. Instead, Dart maintains a
handle map:

```dart
int _nextHandle = 1;
final Map<int, Element> _handles = {};

int _store(Element el) {
  final h = _nextHandle++;
  _handles[h] = el;
  return h;
}

Element? _get(int h) => _handles[h];
void _free(int h) => _handles.remove(h);
```

Python works exclusively with integer handles:

```python
btn = dom_create("button")   # returns 1
dom_text(btn, "Click me")    # passes handle 1
dom_append(app, btn)         # passes handles
dom_on_click(btn)            # blocks on handle 1
```

## JSON Wire Format

All data between layers is JSON. Key message shapes:

**Start request** (bridge -> worker):

```json
{ "type": "start", "code": "...", "extFns": ["dom_create", "log"], "id": 1 }
```

**Pending response** (worker -> bridge -> Dart):

```json
{ "state": "pending", "functionName": "dom_create", "args": ["button"], "id": 1 }
```

**Resume request** (bridge -> worker):

```json
{ "type": "resume", "value": 42, "id": 2 }
```

**Complete response** (worker -> bridge -> Dart):

```json
{ "state": "complete", "ok": true, "value": "done", "id": 3 }
```

## COOP/COEP Requirements

The web server must set these headers for `SharedArrayBuffer` support:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

The showcase uses `coi-serviceworker.js` to inject these headers when
the server doesn't set them natively.

## Comparison with Native Path

| Concern | Web (bridge) | Native (FFI) |
|---------|-------------|--------------|
| Transport | `postMessage` + JSON | `dart:ffi` + C pointers |
| Threading | Web Worker | Dart Isolate |
| WASM compile | Async in Worker | N/A (native binary) |
| Memory | Structured clone | Shared memory + manual alloc/free |
| Snapshot format | base64 string | `Uint8List` via raw pointer |
| Latency per call | ~5-20ms (postMessage overhead) | <1ms (FFI is near-zero) |
