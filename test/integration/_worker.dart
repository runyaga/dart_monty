/// Where the integration tests find core's native worker.
///
/// Until core's M4 ships the worker as a build artifact, dm CI builds it
/// with core's `tool/build_worker.sh` at the pinned core ref and exports
/// its path as `DART_MONTY_WORKER`. Locally, point the same variable at a
/// worker you built; unset, core searches its usual places.
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

/// The worker executable named by `DART_MONTY_WORKER`, or null when unset.
String? get workerLocation {
  final path = Platform.environment['DART_MONTY_WORKER'];

  return path == null || path.isEmpty ? null : path;
}

/// Starts a pool on [workerLocation]; the caller closes it.
Future<Monty> startTestPool({
  int minProcesses = 1,
  int? maxProcesses,
  Duration? checkoutTimeout,
}) => Monty.start(
  minProcesses: minProcesses,
  maxProcesses: maxProcesses,
  checkoutTimeout: checkoutTimeout,
  workerLocation: workerLocation,
);
