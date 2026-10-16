import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  test('facade None is a MontyValue with a null Dart projection', () {
    const MontyValue value = MontyNone();
    expect(value, isA<MontyNone>());
    expect(value.dartValue, isNull);
    expect(value, const MontyNone());
  });

  test('all nine core facade names resolve on this backend', () {
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
    ], hasLength(9));
  });
}
