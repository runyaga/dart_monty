import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Returns a terminal bridge value or rethrows its recorded failure.
MontyValue extractBridgeResult(List<BridgeEvent> events) {
  for (final event in events.reversed) {
    if (event is BridgeRunFinished) {
      // Prefer the typed MontyValue when the bridge attached one. Falling
      // back to fromDart loses typed values (dataclass, namedtuple, ...)
      // because event.value is the dartValue, a plain Dart shape.
      return event.montyValue ?? MontyValue.fromDart(event.value);
    }
    if (event is BridgeRunError) {
      final exception = event.exception;
      if (exception != null) throw exception;
      event.throwCause();
    }
  }

  throw StateError('No terminal event in bridge execution');
}
