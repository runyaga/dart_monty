import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/host/schema.dart'
    show ParityBindingException, mapAndValidate, mapAndValidateParity;
import 'package:test/test.dart';

void main() {
  group('HostParam.toJsonSchema', () {
    test('generates schema from type and description', () {
      const param = HostParam(
        name: 'query',
        type: HostParamType.string,
        description: 'Search query',
      );

      expect(param.toJsonSchema(), {
        'type': 'string',
        'description': 'Search query',
      });
    });

    test('omits description when null', () {
      const param = HostParam(name: 'count', type: HostParamType.integer);

      expect(param.toJsonSchema(), {'type': 'integer'});
    });

    test('maps all HostParamType values', () {
      const cases = {
        HostParamType.string: 'string',
        HostParamType.integer: 'integer',
        HostParamType.number: 'number',
        HostParamType.boolean: 'boolean',
        HostParamType.list: 'array',
        HostParamType.map: 'object',
        HostParamType.any: null,
      };

      for (final entry in cases.entries) {
        final param = HostParam(name: 'x', type: entry.key);
        expect(
          param.toJsonSchema()['type'],
          entry.value,
          reason: '${entry.key} should map to ${entry.value}',
        );
      }
    });

    test('any type produces unconstrained schema (no type key)', () {
      const param = HostParam(
        name: 'value',
        type: HostParamType.any,
        description: 'Accepts anything',
      );

      final schema = param.toJsonSchema();
      expect(schema.containsKey('type'), isFalse);
      expect(schema['description'], 'Accepts anything');
    });

    test('uses jsonSchemaOverride when set', () {
      const override = {
        'type': 'object',
        'properties': {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        'required': ['x', 'y'],
      };

      const param = HostParam(
        name: 'point',
        type: HostParamType.map,
        description: 'A 2D point',
        jsonSchemaOverride: override,
      );

      expect(param.toJsonSchema(), override);
    });

    test('jsonSchemaOverride takes precedence over type and description', () {
      const param = HostParam(
        name: 'color',
        type: HostParamType.string,
        description: 'ignored',
        jsonSchemaOverride: {
          'type': 'string',
          'enum': ['red', 'green', 'blue'],
        },
      );

      final schema = param.toJsonSchema();
      expect(schema['enum'], ['red', 'green', 'blue']);
      expect(schema.containsKey('description'), isFalse);
    });
  });

  group('HostFunctionSchema.toJsonSchema', () {
    test('generates empty object schema for no params', () {
      const schema = HostFunctionSchema(
        name: 'ping',
        description: 'Health check',
      );

      expect(schema.toJsonSchema(), {
        'type': 'object',
        'properties': <String, Object?>{},
      });
    });

    test('generates schema with required and optional params', () {
      const schema = HostFunctionSchema(
        name: 'search',
        description: 'Search documents',
        params: [
          HostParam(
            name: 'query',
            type: HostParamType.string,
            description: 'Search query',
          ),
          HostParam(
            name: 'limit',
            type: HostParamType.integer,
            description: 'Max results',
            isRequired: false,
            defaultValue: MontyInt(10),
          ),
          HostParam(
            name: 'verbose',
            type: HostParamType.boolean,
            isRequired: false,
          ),
        ],
      );

      expect(schema.toJsonSchema(), {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search query'},
          'limit': {'type': 'integer', 'description': 'Max results'},
          'verbose': {'type': 'boolean'},
        },
        'required': ['query'],
      });
    });

    test('omits required key when all params are optional', () {
      const schema = HostFunctionSchema(
        name: 'configure',
        description: 'Set options',
        params: [
          HostParam(
            name: 'timeout',
            type: HostParamType.number,
            isRequired: false,
          ),
        ],
      );

      final jsonSchema = schema.toJsonSchema();
      expect(jsonSchema.containsKey('required'), isFalse);
    });

    test('includes all required params in required list', () {
      const schema = HostFunctionSchema(
        name: 'create',
        description: 'Create resource',
        params: [
          HostParam(name: 'name', type: HostParamType.string),
          HostParam(name: 'tags', type: HostParamType.list),
          HostParam(name: 'meta', type: HostParamType.map),
        ],
      );

      expect(schema.toJsonSchema()['required'], ['name', 'tags', 'meta']);
    });

    test('respects jsonSchemaOverride on individual params', () {
      const schema = HostFunctionSchema(
        name: 'draw',
        description: 'Draw a shape',
        params: [
          HostParam(
            name: 'shape',
            type: HostParamType.string,
            jsonSchemaOverride: {
              'type': 'string',
              'enum': ['circle', 'square', 'triangle'],
              'description': 'Shape type',
            },
          ),
          HostParam(
            name: 'radius',
            type: HostParamType.number,
            isRequired: false,
            description: 'Shape radius',
          ),
        ],
      );

      final jsonSchema = schema.toJsonSchema();
      final properties = jsonSchema['properties']! as Map<String, Object?>;
      final shapeSchema = properties['shape']! as Map<String, Object?>;
      expect(shapeSchema['enum'], ['circle', 'square', 'triangle']);

      final radiusSchema = properties['radius']! as Map<String, Object?>;
      expect(radiusSchema, {'type': 'number', 'description': 'Shape radius'});
    });
  });

  group('HostFunctionSchema.mapAndValidate', () {
    const schema = HostFunctionSchema(
      name: 'greet',
      description: 'Say hello',
      params: [
        HostParam(name: 'name', type: HostParamType.string),
        HostParam(
          name: 'count',
          type: HostParamType.integer,
          isRequired: false,
          defaultValue: MontyInt(1),
        ),
      ],
    );

    test('maps positional args by schema order', () {
      const args = <MontyValue>[MontyString('Alice'), MontyInt(3)];
      const kwargs = <String, MontyValue>{};

      final result = mapAndValidate(schema, args, kwargs);
      expect(result, {
        'name': const MontyString('Alice'),
        'count': const MontyInt(3),
      });
    });

    test('applies default for missing optional positional arg', () {
      const args = <MontyValue>[MontyString('Bob')];
      const kwargs = <String, MontyValue>{};

      final result = mapAndValidate(schema, args, kwargs);
      expect(result, {
        'name': const MontyString('Bob'),
        'count': const MontyInt(1),
      });
    });

    test('an explicitly passed None reaches an any-typed param', () {
      // Explicit None must survive argument mapping into a host handler.
      const sendSchema = HostFunctionSchema(
        name: 'store_value',
        description: 'Store a named value.',
        params: [
          HostParam(name: 'name', type: HostParamType.string),
          HostParam(name: 'message', type: HostParamType.any),
        ],
      );
      const args = <MontyValue>[MontyString('tasks')];
      const kwargs = <String, MontyValue>{'message': MontyNone()};

      expect(mapAndValidate(sendSchema, args, kwargs), {
        'name': const MontyString('tasks'),
        'message': const MontyNone(),
      });
    });

    test('omitting the any-typed param is still an error', () {
      const sendSchema = HostFunctionSchema(
        name: 'store_value',
        description: 'Store a named value.',
        params: [
          HostParam(name: 'name', type: HostParamType.string),
          HostParam(name: 'message', type: HostParamType.any),
        ],
      );
      const args = <MontyValue>[MontyString('tasks')];
      const kwargs = <String, MontyValue>{};

      expect(
        () => mapAndValidate(sendSchema, args, kwargs),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('is missing'),
          ),
        ),
      );
    });

    test('throws FormatException for extra positional args', () {
      const args = <MontyValue>[
        MontyString('A'),
        MontyInt(1),
        MontyString('extra'),
      ];
      const kwargs = <String, MontyValue>{};

      expect(() => mapAndValidate(schema, args, kwargs), throwsFormatException);
    });

    test('kwargs overlay positional args', () {
      const args = <MontyValue>[MontyString('Alice')];
      const kwargs = <String, MontyValue>{'count': MontyInt(5)};

      final result = mapAndValidate(schema, args, kwargs);
      expect(result, {
        'name': const MontyString('Alice'),
        'count': const MontyInt(5),
      });
    });

    test('throws FormatException for unknown kwargs', () {
      const args = <MontyValue>[MontyString('Alice')];
      const kwargs = <String, MontyValue>{'unknown_key': MontyInt(1)};

      expect(() => mapAndValidate(schema, args, kwargs), throwsFormatException);
    });

    test('throws FormatException when required param is missing', () {
      const args = <MontyValue>[];
      const kwargs = <String, MontyValue>{};

      expect(() => mapAndValidate(schema, args, kwargs), throwsFormatException);
    });

    test('validates type of positional args', () {
      const args = <MontyValue>[MontyInt(42)];
      const kwargs = <String, MontyValue>{};

      expect(() => mapAndValidate(schema, args, kwargs), throwsFormatException);
    });

    test('a keyword replaces the positional argument of the same name', () {
      const args = <MontyValue>[MontyString('Alice'), MontyInt(3)];
      const kwargs = <String, MontyValue>{'name': MontyString('Bob')};

      expect(mapAndValidate(schema, args, kwargs), {
        'name': const MontyString('Bob'),
        'count': const MontyInt(3),
      });
    });

    test('names the function and both counts for extra positionals', () {
      const args = <MontyValue>[MontyString('A'), MontyInt(1), MontyInt(2)];

      expect(
        () => mapAndValidate(schema, args, const {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'greet: expected at most 2 positional argument(s), got 3',
          ),
        ),
      );
    });

    test('names the function and the key for an unknown keyword', () {
      expect(
        () => mapAndValidate(schema, const [], const {'typo': MontyInt(1)}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'greet: unknown keyword argument "typo"',
          ),
        ),
      );
    });

    test('works with no params schema', () {
      const emptySchema = HostFunctionSchema(name: 'ping', description: 'Ping');

      const args = <MontyValue>[];
      const kwargs = <String, MontyValue>{};

      final result = mapAndValidate(emptySchema, args, kwargs);
      expect(result, isEmpty);
    });
  });

  group('mapAndValidateParity', () {
    const twoSchema = HostFunctionSchema(
      name: 'two',
      params: [
        HostParam(name: 'a', type: HostParamType.integer),
        HostParam(name: 'b', type: HostParamType.integer),
      ],
    );
    const threeSchema = HostFunctionSchema(
      name: 'three',
      params: [
        HostParam(name: 'a', type: HostParamType.integer),
        HostParam(name: 'b', type: HostParamType.integer),
        HostParam(name: 'c', type: HostParamType.integer),
      ],
    );

    Matcher throwsParityMessage(String expectedMessage) => throwsA(
      isA<ParityBindingException>().having(
        (e) => e.message,
        'message',
        expectedMessage,
      ),
    );

    test('unexpected keyword throws ParityBindingException', () {
      expect(
        () => mapAndValidateParity(
          twoSchema,
          const [MontyInt(1), MontyInt(2)],
          const {'tag': MontyString('first')},
        ),
        throwsParityMessage(
          "two() got an unexpected keyword argument 'tag'",
        ),
      );
    });

    test('multiple values for argument throws ParityBindingException', () {
      expect(
        () => mapAndValidateParity(
          twoSchema,
          const [MontyInt(1), MontyInt(2)],
          const {'a': MontyInt(4)},
        ),
        throwsParityMessage("two() got multiple values for argument 'a'"),
      );
    });

    test('missing 1, 2, and 3 required arguments throw upstream texts', () {
      expect(
        () => mapAndValidateParity(twoSchema, const [MontyInt(1)], const {}),
        throwsParityMessage(
          "two() missing 1 required positional argument: 'b'",
        ),
      );
      expect(
        () => mapAndValidateParity(twoSchema, const [], const {}),
        throwsParityMessage(
          "two() missing 2 required positional arguments: 'a' and 'b'",
        ),
      );
      const expectedThree =
          "three() missing 3 required positional arguments: 'a', 'b', and 'c'";
      expect(
        () => mapAndValidateParity(threeSchema, const [], const {}),
        throwsParityMessage(expectedThree),
      );
    });

    test('too many positional arguments use singular and plural forms', () {
      expect(
        () => mapAndValidateParity(
          twoSchema,
          const [MontyInt(1), MontyInt(2), MontyInt(3)],
          const {},
        ),
        throwsParityMessage(
          'two() takes 2 positional arguments but 3 were given',
        ),
      );
      const oneSchema = HostFunctionSchema(
        name: 'one',
        params: [HostParam(name: 'a', type: HostParamType.integer)],
      );
      expect(
        () => mapAndValidateParity(
          oneSchema,
          const [MontyInt(1), MontyInt(2)],
          const {},
        ),
        throwsParityMessage(
          'one() takes 1 positional argument but 2 were given',
        ),
      );
      const zeroSchema = HostFunctionSchema(name: 'zero');
      expect(
        () => mapAndValidateParity(zeroSchema, const [MontyInt(1)], const {}),
        throwsParityMessage(
          'zero() takes 0 positional arguments but 1 was given',
        ),
      );
    });

    test('schema type mismatch still throws FormatException', () {
      expect(
        () => mapAndValidateParity(
          twoSchema,
          const [MontyString('bad'), MontyInt(2)],
          const {},
        ),
        throwsFormatException,
      );
    });
  });
}
