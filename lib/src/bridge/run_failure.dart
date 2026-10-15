import 'package:dart_monty/src/bridge/event.dart';
import 'package:meta/meta.dart';

/// The original throw behind each [BridgeRunError] the bridge emitted for a
/// failure that is not a `MontyError`, with its stack trace.
final Expando<(Object, StackTrace)> _causes = Expando('run failure');

/// Records [error] and [stackTrace] as the cause of [event].
@internal
void recordRunFailure(
  BridgeRunError event,
  Object error,
  StackTrace stackTrace,
) => _causes[event] = (error, stackTrace);

/// The throw recorded for [event] by [recordRunFailure], or null.
@internal
(Object, StackTrace)? runFailureOf(BridgeRunError event) => _causes[event];
