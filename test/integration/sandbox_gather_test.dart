@Tags(['integration'])
library;

import 'package:collection/collection.dart';
import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_child_contract.dart';

void main() {
  late MontyRuntime runtime;
  setUp(() async {
    runtime = await MontyRuntime.start(
      pool: await childContractPool(),
      extensions: [SandboxExtension()],
    );
  });
  tearDown(() => runtime.dispose());

  Future<List<Object?>> gather(List<MontyValue> handles) async =>
      (await runtime.invoke('sandbox_gather', {
            'handles': MontyList(handles),
          })).dartValue!
          as List<Object?>;

  group('sandbox_gather with real FFI', () {
    test(
      'attributes print output and return value to correct worker',
      () async {
        final handles = <MontyValue>[];
        for (final value in [42, 99, 7]) {
          handles.add(
            await spawnChild(runtime, 'print("worker-$value")\n$value'),
          );
        }
        final values = await gather(handles);
        for (var i = 0; i < values.length; i++) {
          final row = values[i]! as Map;
          expect(row['handle'], handles.elementAtOrNull(i)?.dartValue);
          expect(row['value'], [42, 99, 7].elementAtOrNull(i));
          expect(row['output'], contains('worker-${row['value']}'));
        }
        expect(values, hasLength(3));
      },
    );
    test('gather preserves requested handle order', () async {
      final first = await spawnChild(runtime, '10');
      final second = await spawnChild(runtime, '20');
      final rows = await gather([second, first]);
      expect(rows.map((r) => (r! as Map)['handle']), [
        second.dartValue,
        first.dartValue,
      ]);
      expect(rows.map((r) => (r! as Map)['value']), [20, 10]);
    });
    test('gather with silent worker returns null output', () async {
      final loud = await spawnChild(runtime, 'print("hello")\n1');
      final silent = await spawnChild(runtime, '2');
      final rows = await gather([loud, silent]);
      expect((rows.firstOrNull as Map?)?['output'], contains('hello'));
      expect((rows.elementAtOrNull(1)! as Map)['output'], isNull);
    });
    test('gather propagates child failure as ChildSandboxException', () async {
      final good = await spawnChild(runtime, '1');
      final bad = await spawnChild(runtime, 'undefined_variable_xyz');
      await expectLater(
        gather([good, bad]),
        throwsA(predicate<Object>((e) => e.toString().contains('NameError'))),
      );
    });
    test(
      'gather results are machine-parseable for downstream tooling',
      () async {
        final first = await spawnChild(
          runtime,
          'print("line1")\nprint("line2")\n100',
        );
        final second = await spawnChild(runtime, 'print("only")\n200');
        final rows = await gather([first, second]);
        for (final row in rows.cast<Map<Object?, Object?>>()) {
          expect(row.keys, unorderedEquals(['handle', 'value', 'output']));
          expect(row['handle'], isA<int>());
        }
        expect((rows.firstOrNull as Map?)?['output'], contains('line1\nline2'));
      },
    );
  });
}
