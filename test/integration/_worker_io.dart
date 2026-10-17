/// Where the integration tests find core's native worker.
///
/// Core's build hook installs the prebuilt worker for the host. Set
/// `DART_MONTY_WORKER` to override it with a locally built worker.
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
