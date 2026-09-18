// `asMap()` answers null unless every key is a string.
//
// Added at the dart_monty_core v0.21 uptake, when `MontyDict` stopped keying on
// String. The BEHAVIOUR is not new: before core `45fdb1f` a dict with any
// non-string key was a `MontyPairsDict`, a different type, so this accessor —
// which only ever matched `MontyDict` — already answered null for it. What was
// enforced by the type system is now enforced by a check, so it needs a test
// where it previously needed none.

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  group('MontyValue.asMap', () {
    test('returns the entries of an all-string-keyed dict', () {
      final v = MontyDict.ofStrings(const {
        'a': MontyInt(1),
        'b': MontyString('two'),
      });

      expect(
        v.asMap(),
        equals({'a': const MontyInt(1), 'b': const MontyString('two')}),
      );
    });

    test('returns null when ANY key is not a string', () {
      // The case that used to be a different Dart type. One non-string key is
      // enough: a partial map would silently drop entries, which is worse than
      // saying "not a string-keyed dict".
      // 0.23: MontyDict holds PAIRS, not a Map. A map literal cannot express a
      // non-string key here any more, which is the point of the merge.
      const v = MontyDict([
        (MontyString('a'), MontyInt(1)),
        (MontyInt(2), MontyString('b')),
      ]);

      expect(v.asMap(), isNull);
    });

    test('returns null for a non-dict', () {
      expect(const MontyInt(1).asMap(), isNull);
      expect(const MontyString('x').asMap(), isNull);
    });

    test('an empty dict is an empty map, not null', () {
      // Vacuously all-string-keyed. Answering null here would make "no entries"
      // indistinguishable from "wrong shape".
      expect(MontyDict.ofStrings(const {}).asMap(), isEmpty);
    });
  });
}
