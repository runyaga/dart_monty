import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/runtime/runtime_state.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

/// A real [MontyError] with [message]: errors have no public constructor, so
/// one is raised by a scripted fake session.
Future<MontyError> _error(String message) async {
  final session = FakeMontySession()..willRaise('ValueError', message: message);
  try {
    await session.feedRun('raise ValueError()');
  } on MontyError catch (e) {
    return e;
  }
  throw StateError('the scripted feed did not raise');
}

void main() {
  group('extractBridgeResult', () {
    test('returns value from BridgeRunFinished', () {
      final events = <BridgeEvent>[
        const BridgeRunFinished(
          threadId: 't',
          runId: 'r',
          value: 42,
        ),
      ];
      final result = extractBridgeResult(events);
      expect(result.dartValue, 42);
    });

    test(
      'fails with the message of a BridgeRunError without an exception',
      () {
        final events = <BridgeEvent>[
          const BridgeRunError(message: 'kaboom'),
        ];
        expect(
          () => extractBridgeResult(events),
          throwsA(predicate((e) => '$e'.contains('kaboom'))),
        );
      },
    );

    test('throws BridgeRunError.exception when present', () async {
      final exc = await _error('typed');
      final events = <BridgeEvent>[
        BridgeRunError(message: 'kaboom', exception: exc),
      ];
      expect(() => extractBridgeResult(events), throwsA(same(exc)));
      expect(exc.exception.message, 'typed');
    });

    test('uses last terminal event when multiple events present', () {
      final events = <BridgeEvent>[
        const BridgeRunFinished(threadId: 't', runId: 'r', value: 1),
        const BridgeRunFinished(threadId: 't', runId: 'r', value: 99),
      ];
      final result = extractBridgeResult(events);
      expect(result.dartValue, 99);
    });

    test('preserves typed MontyValue (regression for #384)', () {
      // event.value is the dartValue (a List for a tuple), which would
      // re-parse as MontyList via fromDart. The montyValue field carries the
      // typed value through losslessly.
      const tuple = MontyTuple([MontyString('alice'), MontyInt(30)]);
      final events = <BridgeEvent>[
        BridgeRunFinished(
          threadId: 't',
          runId: 'r',
          value: tuple.dartValue,
          montyValue: tuple,
        ),
      ];
      final result = extractBridgeResult(events);
      expect(result, isA<MontyTuple>());
      expect(result, tuple);
    });

    test('falls back to fromDart when montyValue absent', () {
      // External bridge implementations that don't set montyValue
      // still get a MontyDict from a Map event.value.
      final events = <BridgeEvent>[
        const BridgeRunFinished(
          threadId: 't',
          runId: 'r',
          value: {'k': 1},
        ),
      ];
      final result = extractBridgeResult(events);
      expect(result, isA<MontyDict>());
    });

    test('throws StateError when no terminal event', () {
      expect(
        () => extractBridgeResult([]),
        throwsA(isA<StateError>()),
      );
    });
  });
}
