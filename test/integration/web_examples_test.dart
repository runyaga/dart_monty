@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

// Exercise the same setup as the browser, without JS interop.
// ignore: avoid_relative_lib_imports
import '../../example/web/lib/demo_vfs.dart';
// Reuse the browser workspace and child module policy.
// ignore: avoid_relative_lib_imports
import '../../example/web/lib/runtime_showcase.dart';
import '_worker.dart';

void main() {
  final examples =
      (jsonDecode(
                File('example/web/web/examples.json').readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();
  late Monty pool;
  setUpAll(() async {
    pool = await startTestPool(maxProcesses: 6);
    addTearDown(pool.close);
  });
  for (final example in examples.where((e) => e['legacy'] != true)) {
    test('catalog ${example['id']} exact output', () async {
      final vfs = example['setup'] == 'vfs';
      final visualizer = example['setup'] == 'visualizer';
      final operations = <String>[];
      final files = await createDemoVfs(
        (example['stagedFiles'] as Map?)?.cast<String, String>() ?? {},
      );
      final runtime = vfs
          ? await MontyRuntime.start(
              pool: pool,
              os: (op, args, kwargs) {
                operations.add(op);
                return files.call(op, args, kwargs);
              },
            )
          : await startShowcase(pool, grant: example['setup'] != 'denied');
      addTearDown(runtime.dispose);
      final setup = example['setup'] as String;
      if (setup.startsWith('matrix-')) {
        final gather = setup == 'matrix-gather';
        runtime.register(
          HostFunction(
            schema: HostFunctionSchema(
              name: gather ? 'slow' : 'fetch',
              params: [
                HostParam(
                  name: gather ? 'n' : 'value',
                  type: HostParamType.integer,
                ),
              ],
            ),
            handler: (args, _) async => MontyInt(
              (args[gather ? 'n' : 'value']! as MontyInt).value *
                      (gather ? 10 : 1) +
                  (gather ? 0 : 1),
            ),
            dispatch: setup == 'matrix-future' || gather
                ? DispatchMode.future
                : DispatchMode.sync,
          ),
        );
      }
      final prerequisite = example['requires'];
      if (prerequisite != null) {
        await runtime
            .execute(
              examples.firstWhere((e) => e['id'] == prerequisite)['code']
                  as String,
            )
            .result;
      }
      if (visualizer) {
        runtime.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'yield_state',
              params: [
                HostParam(name: 'arr', type: HostParamType.any),
                HostParam(name: 'i', type: HostParamType.integer),
                HostParam(name: 'j', type: HostParamType.integer),
                HostParam(name: 'action', type: HostParamType.string),
              ],
            ),
            handler: (_, _) async => const MontyNone(),
          ),
        );
      }
      final code = (example['code'] as String).replaceAll(
        'INPUT_ARRAY',
        '[8,7,6,5,4,3,2,1]',
      );
      final result = runtime.execute(code).result;
      if (example['error'] != null) {
        await expectLater(
          result,
          throwsA(
            predicate<Object>(
              (e) => e.toString().contains(example['error'] as String),
            ),
          ),
        );
      } else {
        expect((await result).dartValue, example['expected']);
        if (['walk', 'glob'].contains(example['id'])) {
          expect(
            operations.any((op) => op.toLowerCase().contains('scan')),
            isTrue,
            reason: '$operations',
          );
        }
      }
    });
  }
}
