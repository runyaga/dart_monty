/// The acceptance suite in a browser: a Web Worker per session.
library;

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
