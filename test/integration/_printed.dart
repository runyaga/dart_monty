/// Reads an execution's print text from its terminal event: on core 0.110
/// the result is a bare `MontyValue`, so print output travels on
/// `BridgeRunFinished.printOutput`.
library;

import 'package:dart_monty/dart_monty.dart';

/// Waits for [handle] to finish and returns the print text its
/// `BridgeRunFinished` event carried.
Future<String?> printedBy(ExecutionHandle handle) async {
  final finished = handle.events.firstWhere((e) => e is BridgeRunFinished);
  await handle.result;

  return (await finished as BridgeRunFinished).printOutput;
}
