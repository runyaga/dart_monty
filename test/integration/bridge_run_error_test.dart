@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime_state.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../src/_throwing_session.dart';
import '_worker.dart';

void main() {
  late Monty pool;
  late MontySession session;
  late MontyBridge bridge;

  setUpAll(() async {
    pool = await startTestPool();
  });

  tearDownAll(() async {
    await pool.close();
  });

  setUp(() async {
    session = await pool.checkout();
    bridge = MontyBridge(session: session, logger: BridgeLogger.silent);
  });

  tearDown(() async {
    bridge.dispose();
    await session.close();
  });

  test(
    'Python runtime error populates BridgeRunError getters and throwCause '
    'rethrows with causeStack',
    () async {
      final events = await bridge.execute('print("hi")\n1 / 0').toList();
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      final err = errors.firstOrNull!;
      final runtimeErr = err.exception! as MontyRuntimeError;
      final stack = err.causeStack;
      final prints = err.prints;
      final cause = err.cause;

      expect(err.message, 'ZeroDivisionError: division by zero');
      expect(err.displayMessage, runtimeErr.display());
      expect(err.traceback, runtimeErr.traceback);
      expect(err.exceptionValue, runtimeErr.exception);
      expect(prints, 'hi\n');
      expect(prints, err.printOutput);
      expect(stack, isNotNull);

      Object? extracted;
      try {
        extractBridgeResult(events);
      } on Object catch (e) {
        extracted = e;
      }
      expect(identical(cause, runtimeErr), isTrue);
      expect(identical(cause, extracted), isTrue);

      try {
        err.throwCause();
      } on MontyRuntimeError catch (e, st) {
        expect(identical(e, runtimeErr), isTrue);
        expect('$st', stack?.toString());
      }
    },
  );

  test(
    'MontyCrashedError uses toString() for displayMessage and null traceback',
    () async {
      final fake = FakeMontySession()..willCrash();
      final crashingBridge = MontyBridge(
        session: fake,
        logger: BridgeLogger.silent,
      );
      addTearDown(crashingBridge.dispose);

      final events = await crashingBridge.execute('1 + 1').toList();
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      final err = errors.firstOrNull!;

      expect(err.cause, isA<MontyCrashedError>());
      expect(err.displayMessage, err.exception!.toString());
      expect(err.traceback, isNull);
      expect(err.causeStack, isNotNull);
    },
  );

  test(
    'infrastructure failure preserves exact object and stack on BridgeRunError',
    () async {
      final infraError = StateError('transport disconnected');
      final throwingBridge = MontyBridge(
        session: ThrowingSession(infraError),
        logger: BridgeLogger.silent,
      );
      addTearDown(throwingBridge.dispose);

      final events = await throwingBridge.execute('1 + 1').toList();
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      final err = errors.firstOrNull!;
      final stack = err.causeStack;

      expect(err.exception, isNull);
      expect(err.traceback, isNull);
      expect(err.exceptionValue, isNull);
      expect(err.displayMessage, err.message);
      expect(identical(err.cause, infraError), isTrue);
      expect(stack, isNotNull);

      try {
        err.throwCause();
      } on Object catch (e, st) {
        expect(identical(e, infraError), isTrue);
        expect('$st', stack?.toString());
      }
    },
  );

  test(
    'manually constructed BridgeRunError has null cause/stack and throwCause '
    'throws StateError',
    () {
      const err = BridgeRunError(
        message: 'custom failure',
        printOutput: 'line\n',
      );
      expect(err.displayMessage, 'custom failure');
      expect(err.traceback, isNull);
      expect(err.exceptionValue, isNull);
      expect(err.cause, isNull);
      expect(err.causeStack, isNull);
      expect(err.prints, 'line\n');
      expect(
        err.throwCause,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'custom failure',
          ),
        ),
      );
    },
  );
}
