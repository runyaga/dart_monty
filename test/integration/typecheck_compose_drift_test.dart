@Tags(['integration'])
library;

import 'package:collection/collection.dart';
import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_compose_stub_fixture.g.dart';
import '_worker.dart';

void main() {
  late Monty pool;

  setUpAll(() async => pool = await startTestPool(maxProcesses: 4));
  tearDownAll(() => pool.close());

  for (final fixture in composeFixture.entries) {
    test('${fixture.key} COMPOSE stubs match registrations', () async {
      final runtime = await MontyRuntime.start(
        pool: pool,
        typeCheck: true,
        typeCheckStubs: fixture.value.stubs,
      );
      final registrations = [
        ...fixture.value.functions,
        ...composeAlwaysRegistered,
      ];
      for (final function in registrations) {
        runtime.register(_plain(function.name, function.params));
      }
      try {
        await runtime.execute('None').result;
        final stubbed = _stubFunctions(fixture.value.stubs);
        final registered = {
          for (final schema in runtime.schemas)
            schema.name: [for (final param in schema.params) param.name],
        };
        final relevantRegistered = {
          for (final function in registrations)
            function.name: registered[function.name]!,
        };
        final registeredOnly = relevantRegistered.keys.toSet().difference(
          stubbed.keys.toSet(),
        );
        final expectedDrift = composeUiFamilies.contains(fixture.key)
            ? <String>{}
            : {'ui', 'ui_next'};

        expect(
          stubbed.keys.toSet().difference(relevantRegistered.keys.toSet()),
          isEmpty,
        );
        expect(registeredOnly, expectedDrift);
        for (final entry in stubbed.entries) {
          expect(
            relevantRegistered[entry.key],
            entry.value,
            reason: '${fixture.key}.${entry.key} parameter order',
          );
        }
        await expectLater(
          runtime.execute('list_trips(1)').result,
          throwsA(isA<MontyTypingError>()),
          reason: '${fixture.key}: family stubs are loaded',
        );
      } finally {
        await runtime.dispose();
      }
    });
  }
}

HostFunction _plain(String name, List<String> params) => HostFunction(
  schema: HostFunctionSchema(
    name: name,
    params: [
      for (final param in params)
        HostParam(name: param, type: HostParamType.any),
    ],
  ),
  handler: (_, _) async => const MontyNone(),
);

Map<String, List<String>> _stubFunctions(String stubs) {
  final pattern = RegExp(
    r'^def ([A-Za-z_]\w*)\(([^)]*)\)\s*->',
    multiLine: true,
  );

  return {
    for (final match in pattern.allMatches(stubs))
      match.group(1)!: _parameterNames(match.group(2)!),
  };
}

List<String> _parameterNames(String text) => text.trim().isEmpty
    ? const []
    : [
        for (final parameter in _splitParameters(text))
          parameter.trim().split(':').firstOrNull?.trim() ?? '',
      ];

List<String> _splitParameters(String text) {
  final parameters = <String>[];
  var bracketDepth = 0;
  var start = 0;
  for (var index = 0; index < text.length; index++) {
    switch (text[index]) {
      case '[':
        bracketDepth++;
      case ']':
        bracketDepth--;
      case ',' when bracketDepth == 0:
        parameters.add(text.substring(start, index));
        start = index + 1;
    }
  }
  parameters.add(text.substring(start));

  return parameters;
}
