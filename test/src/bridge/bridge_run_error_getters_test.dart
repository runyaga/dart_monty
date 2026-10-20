import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/run_failure.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

/// Tests of `BridgeRunError`'s derived getters: `displayMessage`, `cause`,
/// `causeStack` and `throwCause`.
///
/// The `MontyTypingError` arm of `displayMessage` is not exercised here: a
/// typing error is made only by core's session from a worker `TypingError`
/// event, which `FakeMontySession` cannot script and whose factory
/// (`typingError`) core does not export, so no fake-driven test can hold one.

/// The error a scripted session's feed ends with: [excType] raised, with
/// [message] and an optional traceback frame at [line].
Future<MontyError> _raised(String excType, {String? message, int? line}) async {
  final session = FakeMontySession()
    ..willRaise(excType, message: message, line: line);
  try {
    await session.feedRun('raise');
    fail('the scripted feed must raise');
  } on MontyError catch (e) {
    return e;
  }
}

/// The `MontyCrashedError` a scripted session's dead worker ends with.
Future<MontyCrashedError> _crashed() async {
  final session = FakeMontySession()..willCrash();
  try {
    await session.feedRun('raise');
    fail('the scripted feed must crash');
  } on MontyCrashedError catch (e) {
    return e;
  }
}

void main() {
  group('displayMessage', () {
    test('a syntax error renders its display', () async {
      final error = await _raised('SyntaxError', message: 'bad');
      expect(error, isA<MontySyntaxError>());
      final syntax = error as MontySyntaxError;

      final event = BridgeRunError(message: 'infrastructure', exception: error);

      expect(event.displayMessage, syntax.display());
      expect(event.displayMessage, 'SyntaxError: bad');
    });

    test('a runtime error renders its traceback display', () async {
      final error = await _raised('ValueError', message: 'v', line: 3);
      expect(error, isA<MontyRuntimeError>());
      final runtime = error as MontyRuntimeError;

      final event = BridgeRunError(message: 'infrastructure', exception: error);

      expect(event.displayMessage, runtime.display());
      expect(event.displayMessage, contains('ValueError: v'));
      expect(event.displayMessage, isNot('infrastructure'));
    });

    test('a crashed worker renders its toString', () async {
      final error = await _crashed();

      final event = BridgeRunError(message: 'infrastructure', exception: error);

      expect(event.displayMessage, error.toString());
      expect(event.displayMessage, contains('crashed'));
    });

    test('no exception leaves the message', () {
      const event = BridgeRunError(message: 'infrastructure only');

      expect(event.displayMessage, 'infrastructure only');
    });
  });

  group('cause', () {
    // Each event's message is unique: a `const BridgeRunError` is
    // canonicalized, and the failure Expando keys on the event's identity,
    // so one shared instance would carry a recorded failure between tests.
    test('is the exception of a manually constructed event', () async {
      final error = await _raised('ValueError', message: 'v');
      final event = BridgeRunError(message: 'm', exception: error);

      expect(event.cause, same(error));
      expect(event.causeStack, isNull);
    });

    test('is the throw recorded for the event, with its stack', () {
      final failure = StateError('infrastructure');
      final stack = StackTrace.current;
      const event = BridgeRunError(message: 'recorded');
      recordRunFailure(event, failure, stack);

      expect(event.cause, same(failure));
      expect(event.causeStack, same(stack));
    });

    test('the exception wins over a recorded failure', () async {
      final error = await _raised('ValueError', message: 'v');
      final event = BridgeRunError(message: 'm', exception: error);
      recordRunFailure(event, StateError('also recorded'), StackTrace.current);

      expect(event.cause, same(error));
    });

    test('is null for an unassociated event', () {
      const event = BridgeRunError(message: 'unassociated');

      expect(event.cause, isNull);
      expect(event.causeStack, isNull);
    });
  });

  group('throwCause', () {
    test('throws the exception of a manually constructed event', () async {
      final error = await _raised('ValueError', message: 'v');
      final event = BridgeRunError(message: 'm', exception: error);

      expect(event.throwCause, throwsA(same(error)));
    });

    test('rethrows a recorded failure with its stack trace', () {
      final failure = StateError('infrastructure');
      final stack = StackTrace.current;
      const event = BridgeRunError(message: 'rethrown');
      recordRunFailure(event, failure, stack);

      late Object thrown;
      late StackTrace thrownStack;
      try {
        event.throwCause();
      } on Object catch (e, s) {
        thrown = e;
        thrownStack = s;
      }

      expect(thrown, same(failure));
      expect(thrownStack.toString(), stack.toString());
    });

    test('throws StateError for an unassociated event', () {
      const event = BridgeRunError(message: 'nothing caused this');

      expect(
        () => event.throwCause(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'nothing '
                'caused this',
          ),
        ),
      );
    });
  });
}
