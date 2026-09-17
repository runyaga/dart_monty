// MontyValueX against values the ENGINE produced.
//
// The extension is public API and its accessors were exercised only by unit
// tests over hand-constructed MontyValue instances — `dcm check-unused-code`
// reports it as "used only in tests", and `asBytes()` appears exactly ONCE in
// the whole repository: its own declaration. Nothing had ever called it.
//
// Hand-built values prove the switch arms compile. They cannot answer the
// question that matters for a typed accessor: does the engine actually hand
// back the subtype the arm is written for? An accessor whose arm never
// matches anything real is dead code wearing a green test.
//
// So every value below comes out of a real FFI run.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

/// Runs [expr] on a real backend and returns the resulting value.
Future<MontyValue> _eval(String expr) async {
  final runtime = MontyRuntime();
  final r = await runtime.execute(expr).result;
  await runtime.dispose();
  expect(r.error, isNull, reason: 'the expression itself must succeed');

  return r.value;
}

void main() {
  group('MontyValueX on engine-produced values', () {
    test('asString matches a Python str and nothing else', () async {
      expect((await _eval('"hello"')).asString(), 'hello');
      expect((await _eval('7')).asString(), isNull);
      expect((await _eval('None')).asString(), isNull);
    });

    test('asInt, asDouble and asBool do not bleed into each other', () async {
      final i = await _eval('7');
      final d = await _eval('7.5');
      final b = await _eval('True');

      expect(i.asInt(), 7);
      expect(i.asDouble(), isNull, reason: 'a Python int is not a float');
      expect(d.asDouble(), 7.5);
      expect(d.asInt(), isNull);
      expect(b.asBool(), isTrue);

      // Python bool IS an int subclass; the accessors must not follow that,
      // or `asInt()` silently succeeds on True and returns 1.
      expect(b.asInt(), isNull);
    });

    test('asList matches all four sequence types the engine emits', () async {
      // Each of these is a separate switch arm. A test over a hand-built
      // MontyList would exercise one arm and leave three unverified against
      // what the engine really returns for tuple/set/frozenset.
      expect((await _eval('[1, 2]')).asList(), hasLength(2));
      expect((await _eval('(1, 2)')).asList(), hasLength(2));
      expect((await _eval('{1, 2}')).asList(), hasLength(2));
      expect((await _eval('frozenset({1, 2})')).asList(), hasLength(2));

      expect(
        (await _eval('"ab"')).asList(),
        isNull,
        reason: 'str is not a seq',
      );
    });

    test(
      'asMap returns string-keyed dicts and NULL for other keyspaces',
      () async {
        final strKeyed = await _eval('{"a": 1, "b": 2}');
        expect(strKeyed.asMap(), isNotNull);
        expect(strKeyed.asMap()!.keys, containsAll(['a', 'b']));

        // The documented contract: asStringMap returns null unless EVERY key
        // is a string. Verified against a dict the engine built, not one
        // assembled in Dart.
        expect((await _eval('{1: "x"}')).asMap(), isNull);
        expect((await _eval('{"a": 1, 2: "b"}')).asMap(), isNull);
      },
    );

    test(
      'asBytes matches Python bytes — the arm nothing had ever called',
      () async {
        final v = await _eval('b"abc"');

        expect(
          v.asBytes(),
          [97, 98, 99],
          reason:
              'the engine must return MontyBytes for a bytes literal, or '
              'this accessor can never match anything',
        );
        expect(
          (await _eval('"abc"')).asBytes(),
          isNull,
          reason: 'str != bytes',
        );
      },
    );

    test('isNone is true only for Python None', () async {
      expect((await _eval('None')).isNone, isTrue);
      expect((await _eval('0')).isNone, isFalse);
      expect((await _eval('""')).isNone, isFalse);
      expect((await _eval('[]')).isNone, isFalse);
    });
  });
}
