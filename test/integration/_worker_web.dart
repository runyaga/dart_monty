/// Browser worker location: core's committed assets, served under `packages/`.
library;

import 'package:dart_monty_core/dart_monty_core.dart';

/// Browsers use core's default asset discovery.
String? get workerLocation => null;

/// Starts a pool on core's Web Worker assets; the caller closes it.
Future<Monty> startTestPool({
  int minProcesses = 1,
  int? maxProcesses,
  Duration? checkoutTimeout,
}) => Monty.start(
  minProcesses: minProcesses,
  maxProcesses: maxProcesses,
  checkoutTimeout: checkoutTimeout,
);
