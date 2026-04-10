import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
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
      const param = HostParam(
        name: 'count',
        type: HostParamType.integer,
      );

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
            defaultValue: 10,
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
          defaultValue: 1,
        ),
      ],
    );

    test('maps positional args by schema order', () {
      const pending = MontyPending(
        functionName: 'greet',
        arguments: [MontyString('Alice'), MontyInt(3)],
      );

      final result = schema.mapAndValidate(pending);
      expect(result, {'name': 'Alice', 'count': 3});
    });

    test('applies default for missing optional positional arg', () {
      const pending = MontyPending(
        functionName: 'greet',
        arguments: [MontyString('Bob')],
      );

      final result = schema.mapAndValidate(pending);
      expect(result, {'name': 'Bob', 'count': 1});
    });

    test('throws FormatException for extra positional args', () {
      const pending = MontyPending(
        functionName: 'greet',
        arguments: [MontyString('A'), MontyInt(1), MontyString('extra')],
      );

      expect(() => schema.mapAndValidate(pending), throwsFormatException);
    });

    test('kwargs overlay positional args', () {
      const pending = MontyPending(
        functionName: 'greet',
        arguments: [MontyString('Alice')],
        kwargs: {'count': MontyInt(5)},
      );

      final result = schema.mapAndValidate(pending);
      expect(result, {'name': 'Alice', 'count': 5});
    });

    test('throws FormatException for unknown kwargs', () {
      const pending = MontyPending(
        functionName: 'greet',
        arguments: [MontyString('Alice')],
        kwargs: {'unknown_key': MontyInt(1)},
      );

      expect(() => schema.mapAndValidate(pending), throwsFormatException);
    });

    test('throws FormatException when required param is missing', () {
      const pending = MontyPending(
        functionName: 'greet',
        arguments: [],
      );

      expect(() => schema.mapAndValidate(pending), throwsFormatException);
    });

    test('validates type of positional args', () {
      const pending = MontyPending(
        functionName: 'greet',
        arguments: [MontyInt(42)],
      );

      expect(() => schema.mapAndValidate(pending), throwsFormatException);
    });

    test('works with no params schema', () {
      const emptySchema = HostFunctionSchema(
        name: 'ping',
        description: 'Ping',
      );

      const pending = MontyPending(
        functionName: 'ping',
        arguments: [],
      );

      final result = emptySchema.mapAndValidate(pending);
      expect(result, isEmpty);
    });
  });
}
