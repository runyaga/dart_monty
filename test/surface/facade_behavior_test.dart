import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  test('facade None is a MontyValue with a null Dart projection', () {
    const MontyValue value = MontyNone();
    expect(value, isA<MontyNone>());
    expect(value.dartValue, isNull);
    expect(value, const MontyNone());
  });

  test('all 25 core facade names resolve on this backend', () {
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
    ], hasLength(25));
  });
}
