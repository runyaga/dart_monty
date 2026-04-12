import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  // MontyBytes
  // -------------------------------------------------------------------------
  group('MontyBytes', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'bytes',
        'value': [72, 101, 108, 108, 111],
      });
      expect(v, isA<MontyBytes>());
      expect((v as MontyBytes).value, [72, 101, 108, 108, 111]);
    });

    test('toJson', () {
      const v = MontyBytes([1, 2, 3]);
      expect(v.toJson(), {
        '__type': 'bytes',
        'value': [1, 2, 3],
      });
    });

    test('round-trip', () {
      const v = MontyBytes([1, 2, 3]);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(const MontyBytes([1, 2]), equals(const MontyBytes([1, 2])));
    });

    test('equality different', () {
      expect(const MontyBytes([1, 2]), isNot(equals(const MontyBytes([3, 4]))));
    });

    test('hashCode consistent', () {
      expect(
        const MontyBytes([1, 2]).hashCode,
        const MontyBytes([1, 2]).hashCode,
      );
    });

    test('toString', () {
      expect(const MontyBytes([1]).toString(), 'MontyBytes(1 bytes)');
    });

    test('dartValue returns List<int>', () {
      expect(const MontyBytes([1, 2]).dartValue, isA<List<int>>());
    });

    test('empty bytes', () {
      const v = MontyBytes([]);
      expect(v.value, isEmpty);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('full 0-255 range', () {
      final bytes = List<int>.generate(256, (i) => i);
      final v = MontyBytes(bytes);
      final rt = MontyValue.fromJson(v.toJson()) as MontyBytes;
      expect(rt.value, bytes);
    });
  });

  // -------------------------------------------------------------------------
  // MontyList
  // -------------------------------------------------------------------------
  group('MontyList', () {
    test('fromJson with plain list', () {
      final v = MontyValue.fromJson([1, 'two', true]);
      expect(v, isA<MontyList>());
      final list = v as MontyList;
      expect(list.items.length, 3);
      expect(list.items[0], isA<MontyInt>());
      expect(list.items[1], isA<MontyString>());
      expect(list.items[2], isA<MontyBool>());
    });

    test('toJson', () {
      const v = MontyList([MontyInt(1), MontyString('two')]);
      expect(v.toJson(), [1, 'two']);
    });

    test('round-trip', () {
      const v = MontyList([MontyInt(1), MontyBool(true)]);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontyList([MontyInt(1)]),
        equals(const MontyList([MontyInt(1)])),
      );
    });

    test('equality different', () {
      expect(
        const MontyList([MontyInt(1)]),
        isNot(equals(const MontyList([MontyInt(2)]))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontyList([MontyInt(1)]).hashCode,
        const MontyList([MontyInt(1)]).hashCode,
      );
    });

    test('toString', () {
      expect(const MontyList([]).toString(), 'MontyList(0 items)');
    });

    test('dartValue returns List<Object?>', () {
      const v = MontyList([MontyInt(1), MontyString('a')]);
      expect(v.dartValue, [1, 'a']);
    });

    test('empty list', () {
      final v = MontyValue.fromJson(<dynamic>[]);
      expect(v, isA<MontyList>());
      expect((v as MontyList).items, isEmpty);
    });

    test('nested lists', () {
      final v = MontyValue.fromJson([
        [1, 2],
        [3, 4],
      ]);
      expect(v, isA<MontyList>());
      final outer = v as MontyList;
      expect(outer.items[0], isA<MontyList>());
      expect((outer.items[0] as MontyList).items.length, 2);
    });

    test('mixed types', () {
      final v = MontyValue.fromJson([1, 'str', null, true, 3.14]);
      final list = v as MontyList;
      expect(list.items[0], isA<MontyInt>());
      expect(list.items[1], isA<MontyString>());
      expect(list.items[2], isA<MontyNull>());
      expect(list.items[3], isA<MontyBool>());
      expect(list.items[4], isA<MontyFloat>());
    });
  });

  // -------------------------------------------------------------------------
  // MontyTuple
  // -------------------------------------------------------------------------
  group('MontyTuple', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'tuple',
        'value': [1, 'two'],
      });
      expect(v, isA<MontyTuple>());
      final tuple = v as MontyTuple;
      expect(tuple.items.length, 2);
      expect(tuple.items[0], isA<MontyInt>());
      expect(tuple.items[1], isA<MontyString>());
    });

    test('toJson', () {
      const v = MontyTuple([MontyInt(1), MontyString('two')]);
      expect(v.toJson(), {
        '__type': 'tuple',
        'value': [1, 'two'],
      });
    });

    test('round-trip', () {
      const v = MontyTuple([MontyInt(1), MontyBool(false)]);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontyTuple([MontyInt(1)]),
        equals(const MontyTuple([MontyInt(1)])),
      );
    });

    test('equality different', () {
      expect(
        const MontyTuple([MontyInt(1)]),
        isNot(equals(const MontyTuple([MontyInt(2)]))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontyTuple([MontyInt(1)]).hashCode,
        const MontyTuple([MontyInt(1)]).hashCode,
      );
    });

    test('toString', () {
      expect(const MontyTuple([]).toString(), 'MontyTuple(0 items)');
    });

    test('dartValue returns List<Object?>', () {
      const v = MontyTuple([MontyInt(1)]);
      expect(v.dartValue, isA<List<Object?>>());
    });

    test('empty tuple', () {
      final v = MontyValue.fromJson({'__type': 'tuple', 'value': <dynamic>[]});
      expect(v, isA<MontyTuple>());
      expect((v as MontyTuple).items, isEmpty);
    });

    test('nested tuple', () {
      const inner = MontyTuple([MontyInt(1)]);
      const outer = MontyTuple([inner]);
      final rt = MontyValue.fromJson(outer.toJson()) as MontyTuple;
      expect(rt.items[0], isA<MontyTuple>());
    });
  });

  // -------------------------------------------------------------------------
  // MontyDict
  // -------------------------------------------------------------------------
  group('MontyDict', () {
    test('fromJson with plain map', () {
      final v = MontyValue.fromJson({'a': 1, 'b': 'two'});
      expect(v, isA<MontyDict>());
      final dict = v as MontyDict;
      expect(dict.entries['a'], isA<MontyInt>());
      expect(dict.entries['b'], isA<MontyString>());
    });

    test('toJson', () {
      const v = MontyDict({'key': MontyInt(42)});
      expect(v.toJson(), {'key': 42});
    });

    test('round-trip', () {
      const v = MontyDict({'x': MontyInt(1), 'y': MontyString('hi')});
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontyDict({'a': MontyInt(1)}),
        equals(const MontyDict({'a': MontyInt(1)})),
      );
    });

    test('equality different', () {
      expect(
        const MontyDict({'a': MontyInt(1)}),
        isNot(equals(const MontyDict({'a': MontyInt(2)}))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontyDict({'a': MontyInt(1)}).hashCode,
        const MontyDict({'a': MontyInt(1)}).hashCode,
      );
    });

    test('toString', () {
      expect(const MontyDict({}).toString(), 'MontyDict(0 entries)');
    });

    test('dartValue returns Map<String, Object?>', () {
      const v = MontyDict({'k': MontyInt(1)});
      expect(v.dartValue, isA<Map<String, Object?>>());
      expect(v.dartValue, {'k': 1});
    });

    test('empty dict', () {
      final v = MontyValue.fromJson(<String, dynamic>{});
      expect(v, isA<MontyDict>());
      expect((v as MontyDict).entries, isEmpty);
    });

    test('nested dicts', () {
      final v = MontyValue.fromJson({
        'outer': {'inner': 42},
      });
      expect(v, isA<MontyDict>());
      final outer = v as MontyDict;
      expect(outer.entries['outer'], isA<MontyDict>());
    });
  });

  // -------------------------------------------------------------------------
  // MontySet
  // -------------------------------------------------------------------------
  group('MontySet', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'set',
        'value': [1, 2, 3],
      });
      expect(v, isA<MontySet>());
      expect((v as MontySet).items.length, 3);
    });

    test('toJson', () {
      const v = MontySet([MontyInt(1), MontyInt(2)]);
      expect(v.toJson(), {
        '__type': 'set',
        'value': [1, 2],
      });
    });

    test('round-trip', () {
      const v = MontySet([MontyInt(1), MontyString('a')]);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontySet([MontyInt(1)]),
        equals(const MontySet([MontyInt(1)])),
      );
    });

    test('equality different', () {
      expect(
        const MontySet([MontyInt(1)]),
        isNot(equals(const MontySet([MontyInt(2)]))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontySet([MontyInt(1)]).hashCode,
        const MontySet([MontyInt(1)]).hashCode,
      );
    });

    test('toString', () {
      expect(const MontySet([]).toString(), 'MontySet(0 items)');
    });

    test('dartValue returns List<Object?>', () {
      const v = MontySet([MontyInt(1)]);
      expect(v.dartValue, isA<List<Object?>>());
    });

    test('empty set', () {
      final v = MontyValue.fromJson({'__type': 'set', 'value': <dynamic>[]});
      expect(v, isA<MontySet>());
      expect((v as MontySet).items, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // MontyFrozenSet
  // -------------------------------------------------------------------------
  group('MontyFrozenSet', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'frozenset',
        'value': [1, 2],
      });
      expect(v, isA<MontyFrozenSet>());
      expect((v as MontyFrozenSet).items.length, 2);
    });

    test('toJson', () {
      const v = MontyFrozenSet([MontyInt(1)]);
      expect(v.toJson(), {
        '__type': 'frozenset',
        'value': [1],
      });
    });

    test('round-trip', () {
      const v = MontyFrozenSet([MontyInt(1), MontyString('a')]);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontyFrozenSet([MontyInt(1)]),
        equals(const MontyFrozenSet([MontyInt(1)])),
      );
    });

    test('equality different', () {
      expect(
        const MontyFrozenSet([MontyInt(1)]),
        isNot(equals(const MontyFrozenSet([MontyInt(2)]))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontyFrozenSet([MontyInt(1)]).hashCode,
        const MontyFrozenSet([MontyInt(1)]).hashCode,
      );
    });

    test('toString', () {
      expect(const MontyFrozenSet([]).toString(), 'MontyFrozenSet(0 items)');
    });

    test('dartValue returns List<Object?>', () {
      const v = MontyFrozenSet([MontyInt(1)]);
      expect(v.dartValue, isA<List<Object?>>());
    });

    test('empty frozenset', () {
      final v = MontyValue.fromJson({
        '__type': 'frozenset',
        'value': <dynamic>[],
      });
      expect(v, isA<MontyFrozenSet>());
      expect((v as MontyFrozenSet).items, isEmpty);
    });
  });
}
