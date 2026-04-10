import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  // MontyPath
  // -------------------------------------------------------------------------
  group('MontyPath', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'path',
        'value': '/home/user/file.txt',
      });
      expect(v, isA<MontyPath>());
      expect((v as MontyPath).value, '/home/user/file.txt');
    });

    test('toJson', () {
      const v = MontyPath('/tmp/test');
      expect(v.toJson(), {'__type': 'path', 'value': '/tmp/test'});
    });

    test('round-trip', () {
      const v = MontyPath('/tmp/test');
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(const MontyPath('/a'), equals(const MontyPath('/a')));
    });

    test('equality different', () {
      expect(const MontyPath('/a'), isNot(equals(const MontyPath('/b'))));
    });

    test('hashCode consistent', () {
      expect(
        const MontyPath('/a').hashCode,
        const MontyPath('/a').hashCode,
      );
    });

    test('toString is non-empty', () {
      expect(const MontyPath('/a').toString(), isNotEmpty);
    });

    test('dartValue returns String', () {
      expect(const MontyPath('/a').dartValue, isA<String>());
      expect(const MontyPath('/a').dartValue, '/a');
    });

    test('empty string path', () {
      const v = MontyPath('');
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('unicode path', () {
      const v = MontyPath('/home/user/\u00e9\u00e8\u00ea');
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('path with spaces', () {
      const v = MontyPath('/home/my documents/file name.txt');
      expect(MontyValue.fromJson(v.toJson()), v);
    });
  });

  // -------------------------------------------------------------------------
  // MontyNamedTuple
  // -------------------------------------------------------------------------
  group('MontyNamedTuple', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'namedtuple',
        'type_name': 'Point',
        'field_names': ['x', 'y'],
        'values': [1, 2],
      });
      expect(v, isA<MontyNamedTuple>());
      final nt = v as MontyNamedTuple;
      expect(nt.typeName, 'Point');
      expect(nt.fieldNames, ['x', 'y']);
      expect(nt.values.length, 2);
    });

    test('toJson', () {
      const v = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      expect(v.toJson(), {
        '__type': 'namedtuple',
        'type_name': 'Point',
        'field_names': ['x', 'y'],
        'values': [1, 2],
      });
    });

    test('round-trip', () {
      const v = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: ['x', 'y'],
        values: [MontyInt(1), MontyInt(2)],
      );
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      const a = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      const b = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      expect(a, equals(b));
    });

    test('equality different', () {
      const a = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      const b = MontyNamedTuple(
        typeName: 'Q',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      expect(a, isNot(equals(b)));
    });

    test('hashCode consistent', () {
      const a = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      const b = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      expect(a.hashCode, b.hashCode);
    });

    test('toString is non-empty', () {
      const v = MontyNamedTuple(
        typeName: 'P',
        fieldNames: [],
        values: [],
      );
      expect(v.toString(), isNotEmpty);
    });

    test('dartValue returns Map', () {
      const v = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      expect(v.dartValue, isA<Map<String, Object?>>());
    });

    test('empty fields', () {
      const v = MontyNamedTuple(
        typeName: 'Empty',
        fieldNames: [],
        values: [],
      );
      expect(MontyValue.fromJson(v.toJson()), v);
    });
  });

  // -------------------------------------------------------------------------
  // MontyDataclass
  // -------------------------------------------------------------------------
  group('MontyDataclass', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'dataclass',
        'name': 'Person',
        'type_id': 42,
        'field_names': ['name', 'age'],
        'attrs': {'name': 'Alice', 'age': 30},
        'frozen': false,
      });
      expect(v, isA<MontyDataclass>());
      final dc = v as MontyDataclass;
      expect(dc.name, 'Person');
      expect(dc.typeId, 42);
      expect(dc.fieldNames, ['name', 'age']);
      expect(dc.attrs['name'], isA<MontyString>());
      expect(dc.attrs['age'], isA<MontyInt>());
      expect(dc.frozen, false);
    });

    test('toJson', () {
      const v = MontyDataclass(
        name: 'Person',
        typeId: 42,
        fieldNames: ['name'],
        attrs: {'name': MontyString('Alice')},
      );
      final json = v.toJson();
      expect(json['__type'], 'dataclass');
      expect(json['name'], 'Person');
      expect(json['type_id'], 42);
      expect(json['frozen'], false);
    });

    test('round-trip', () {
      const v = MontyDataclass(
        name: 'Person',
        typeId: 42,
        fieldNames: ['name', 'age'],
        attrs: {'name': MontyString('Alice'), 'age': MontyInt(30)},
        frozen: true,
      );
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      const a = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: ['x'],
        attrs: {'x': MontyInt(1)},
      );
      const b = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: ['x'],
        attrs: {'x': MontyInt(1)},
      );
      expect(a, equals(b));
    });

    test('equality different', () {
      const a = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: ['x'],
        attrs: {'x': MontyInt(1)},
      );
      const b = MontyDataclass(
        name: 'Q',
        typeId: 1,
        fieldNames: ['x'],
        attrs: {'x': MontyInt(1)},
      );
      expect(a, isNot(equals(b)));
    });

    test('hashCode consistent', () {
      const a = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: ['x'],
        attrs: {'x': MontyInt(1)},
      );
      const b = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: ['x'],
        attrs: {'x': MontyInt(1)},
      );
      expect(a.hashCode, b.hashCode);
    });

    test('toString is non-empty', () {
      const v = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: [],
        attrs: {},
      );
      expect(v.toString(), isNotEmpty);
    });

    test('dartValue returns Map', () {
      const v = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: [],
        attrs: {},
      );
      expect(v.dartValue, isA<Map<String, Object?>>());
    });

    test('frozen=true', () {
      const v = MontyDataclass(
        name: 'P',
        typeId: 1,
        fieldNames: [],
        attrs: {},
        frozen: true,
      );
      expect(MontyValue.fromJson(v.toJson()), v);
      expect((MontyValue.fromJson(v.toJson()) as MontyDataclass).frozen, true);
    });

    test('nested attrs', () {
      const inner = MontyDataclass(
        name: 'Inner',
        typeId: 2,
        fieldNames: ['val'],
        attrs: {'val': MontyInt(99)},
      );
      const outer = MontyDataclass(
        name: 'Outer',
        typeId: 1,
        fieldNames: ['child'],
        attrs: {'child': inner},
      );
      final rt = MontyValue.fromJson(outer.toJson()) as MontyDataclass;
      expect(rt.attrs['child'], isA<MontyDataclass>());
      expect((rt.attrs['child']! as MontyDataclass).name, 'Inner');
    });
  });
}
