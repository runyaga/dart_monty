/// The acceptance suite in a browser: a Web Worker per session.
library;

import 'dart:js_interop';

@JS('eval')
external JSAny? _eval(String code);

@JS('__montyLiveWorkers')
external JSNumber? get _liveWorkerCount;

/// Where the pool finds the worker's assets: dart_monty_core's committed
/// `dart_monty_core_worker.{js,wasm}`, which the test server serves under
/// `packages/`.
String get acceptanceWorkerLocation => 'packages/dart_monty_core/assets';

/// Whether workers are operating-system processes with ids.
const bool hasWorkerProcesses = false;

/// A Web Worker has no process id to kill.
bool killWorker(int pid) =>
    throw UnsupportedError('a Web Worker has no process id');

/// A Web Worker has no process id.
Future<bool> processAlive(int pid) =>
    throw UnsupportedError('a Web Worker has no process id');

/// Wraps the page's `Worker` constructor once, so [liveWorkers] can count the
/// Web Workers started and not yet terminated. Call before the first pool
/// starts.
void countWorkers() {
  _eval('''
if (!globalThis.__montyLiveWorkers && globalThis.__montyLiveWorkers !== 0) {
  globalThis.__montyLiveWorkers = 0;
  const Original = globalThis.Worker;
  globalThis.Worker = function (...args) {
    const worker = new Original(...args);
    globalThis.__montyLiveWorkers++;
    const terminate = worker.terminate.bind(worker);
    let ended = false;
    worker.terminate = () => {
      if (!ended) { ended = true; globalThis.__montyLiveWorkers--; }
      terminate();
    };
    return worker;
  };
  globalThis.Worker.prototype = Original.prototype;
}
''');
}

/// The Web Workers started and not yet terminated, as [countWorkers]
/// counts them.
Future<int?> liveWorkers() => Future.value(_liveWorkerCount!.toDartInt);
