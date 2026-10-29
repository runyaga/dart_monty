import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show MontyHostFunction;
import 'package:test/test.dart';

void main() {
  test('facade checkout imports and calls a host module', () async {
    final pool = await Monty.start();
    addTearDown(pool.close);
    final session = await pool.checkout(
      externalModules: {
        'host_tools': ExternalModule({
          'answer': MontyHostFunction('answer', (_, _) => const MontyInt(42)),
        }),
      },
    );
    addTearDown(session.close);
    expect(
      await session.feedRun('import host_tools\nhost_tools.answer()'),
      const MontyInt(42),
    );
  });

  test('facade None is a MontyValue with a null Dart projection', () {
    const MontyValue value = MontyNone();
    expect(value, isA<MontyNone>());
    expect(value.dartValue, isNull);
    expect(value, const MontyNone());
  });

  test('all 26 core facade names resolve on this backend', () {
    expect([
      Monty,
      MontySession,
      MontyValue,
      MontyNone,
      MontyError,
      ResourceLimits,
      OsHandler,
      OsCallNotHandledException,
      ExternalException,
      ExternalModule,
      OSAccess,
      MontyBool,
      MontyInt,
      MontyFloat,
      MontyString,
      MontyList,
      MontyTuple,
      MontyDict,
      MontyBytes,
      Frame,
      MontyRuntimeError,
      MontySyntaxError,
      MontyTypingError,
      MontyCrashedError,
      MontyExceptionValue,
      FrameTooLargeException,
    ], hasLength(26));
  });
}
