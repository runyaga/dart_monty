// `datetime.now()` must carry the full sub-second part.
//
// Dart's `DateTime.microsecond` is only the part below one millisecond
// (0–999); the sub-second value Python's `datetime.microsecond` expects is
// `millisecond * 1000 + microsecond`.
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  final frozen = DateTime(2024, 3, 15, 12, 34, 56, 123, 456);
  const expected = 123456;
  final time = timeHandler(clock: () => frozen);

  test('datetime.now() keeps milliseconds in the microsecond field', () async {
    final v = await time('datetime.now', [null], null);
    expect(
      v,
      isA<MontyDateTime>().having(
        (d) => d.microsecond,
        'microsecond',
        expected,
      ),
    );
  });

  test(
    'datetime.now(tz) keeps milliseconds in the microsecond field',
    () async {
      const utc = MontyTimeZone(offsetSeconds: 0, name: 'UTC');
      final v = await time('datetime.now', [utc.toJson()], null);
      expect(
        v,
        isA<MontyDateTime>().having(
          (d) => d.microsecond,
          'microsecond',
          expected,
        ),
      );
    },
  );
}
