// Explicit float spelling documents numeric kind and signed zero.
// ignore_for_file: prefer_int_literals
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/host/schema.dart' show mapAndValidate;
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '_typed_host_runtime.dart';

void main() {
  test('D3-absent-default-none', () {
    const param = HostParam(
      name: 'x',
      type: HostParamType.string,
      isRequired: false,
    );
    expect(param.validate(null, isPresent: false), const MontyNone());
    expect(() => param.validate(null), throwsArgumentError);
  });

  test('D3-explicit-none', () {
    const param = HostParam(
      name: 'x',
      type: HostParamType.string,
      isRequired: false,
      defaultValue: MontyString('default'),
    );
    expect(param.validate(const MontyNone()), const MontyNone());
    expect(
      identical(param.validate(null, isPresent: false), param.defaultValue),
      isTrue,
    );
  });

  test('D3-bigint-dict', () {
    const child = MontyList([MontyInt(1)]);
    const value = MontyDict([
      (MontyInt(1), child),
      (MontyTuple([MontyInt(2)]), child),
    ]);
    const schema = HostFunctionSchema(
      name: 'probe',
      params: [
        HostParam(name: 'x', type: HostParamType.map),
      ],
    );
    expect(identical(mapAndValidate(schema, [value], {})['x'], value), isTrue);
  });
  final integer = MontyBigInt(BigInt.one << 100);
  final values = <MontyValue>[
    const MontyString('s'),
    const MontyInt(1),
    integer,
    const MontyFloat(1.0),
    const MontyFloat(-0.0),
    const MontyBool(true),
    const MontyList([]),
    const MontyTuple([]),
    const MontyDict([]),
    const MontyNone(),
    MontyPath('/x'),
  ];
  for (final type in HostParamType.values) {
    test('D3-matrix $type', () {
      final param = HostParam(name: 'x', type: type);
      for (final value in values) {
        final accepted = switch (type) {
          HostParamType.string => value is MontyString,
          HostParamType.integer => value is MontyInt || value is MontyBigInt,
          HostParamType.number =>
            value is MontyInt || value is MontyBigInt || value is MontyFloat,
          HostParamType.boolean => value is MontyBool,
          HostParamType.list => value is MontyList,
          HostParamType.map => value is MontyDict,
          HostParamType.any => true,
        };
        if (accepted) {
          expect(identical(param.validate(value), value), isTrue);
        } else {
          expect(() => param.validate(value), throwsFormatException);
        }
      }
    });
    for (final required in [false, true]) {
      test('D3-default-registration $type required=$required', () async {
        final bridge = MontyBridge(session: FakeMontySession());
        addTearDown(bridge.dispose);
        final param = HostParam(
          name: 'x',
          type: type,
          isRequired: required,
          defaultValue: const MontyNone(),
        );
        final fn = HostFunction(
          schema: HostFunctionSchema(name: 'probe', params: [param]),
          handler: (args, _) async => args['x']!,
        );
        if (required && type != HostParamType.any) {
          expect(() => bridge.register(fn), throwsFormatException);
        } else {
          bridge.register(fn);
          expect(
            await bridge.invokeHostFunction('probe', {'x': const MontyNone()}),
            const MontyNone(),
          );
          if (required) {
            expect(
              () => bridge.invokeHostFunction('probe', {}),
              throwsFormatException,
            );
          } else {
            expect(
              await bridge.invokeHostFunction('probe', {}),
              const MontyNone(),
            );
          }
        }
      });
    }
  }

  test('D3-invalid-default-is-rejected-at-registration', () {
    final bridge = MontyBridge(session: FakeMontySession());
    addTearDown(bridge.dispose);
    expect(
      () => bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'probe',
            params: [
              HostParam(
                name: 'x',
                type: HostParamType.integer,
                defaultValue: MontyFloat(1.0),
              ),
            ],
          ),
          handler: (_, _) async => const MontyNone(),
        ),
      ),
      throwsFormatException,
    );
  });

  test('D3-required-default-does-not-satisfy-omission', () {
    const param = HostParam(
      name: 'x',
      type: HostParamType.integer,
      defaultValue: MontyInt(1),
    );
    expect(() => param.validate(null, isPresent: false), throwsFormatException);
  });

  group('real workers', registerTypedHostRuntimeTests);
}
