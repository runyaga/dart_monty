/// The acceptance suite on the VM: a worker process per session.
library;

import 'dart:io';

/// The locally built worker named by `DART_MONTY_WORKER`, or core's prebuilt
/// worker when the variable is unset.
String? get acceptanceWorkerLocation {
  final path = Platform.environment['DART_MONTY_WORKER'];

  return path == null || path.isEmpty ? null : path;
}

/// Whether workers are operating-system processes with ids.
const bool hasWorkerProcesses = true;

/// Kills the worker process [pid], as an out-of-memory kill would.
bool killWorker(int pid) => Process.killPid(pid, ProcessSignal.sigkill);

/// Whether a process [pid] still exists.
Future<bool> processAlive(int pid) async {
  if (Platform.isWindows) {
    final out = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);

    return '${out.stdout}'.contains('$pid');
  }

  // SIGCONT changes nothing for a running process, and fails for one that
  // is gone.
  return Process.killPid(pid, ProcessSignal.sigcont);
}

/// Nothing to install: worker processes are counted by the OS.
void countWorkers() {}

/// The worker processes this process has started that are still running.
///
/// Null where the count is not available (Windows), so a test skips the
/// check instead of passing it.
Future<int?> liveWorkers() async {
  if (Platform.isWindows) return null;
  // `-f`: Linux truncates a process name to 15 characters, so `-x` with
  // the 17-character executable name never matches there.
  final out = await Process.run('pgrep', [
    '-P',
    '$pid',
    '-f',
    r'(^|/)dart_monty_worker( |$)',
  ]);
  // pgrep exits 1 when nothing matches.
  if (out.exitCode > 1) throw StateError('pgrep failed: ${out.stderr}');

  return '${out.stdout}'.split('\n').where((l) => l.trim().isNotEmpty).length;
}
