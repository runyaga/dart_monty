@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

// Exercise the browser demo's filesystem without importing its JS entrypoint.
// The root package does not depend on the nested example package.
// ignore: avoid_relative_lib_imports
import '../../example/web/lib/demo_vfs.dart';
import '_worker.dart';

void main() {
  late Monty pool;
  setUpAll(() async {
    pool = await startTestPool();
  });
  tearDownAll(() => pool.close());

  test('VFS catalog walk runs without staged files', () async {
    final examples =
        (jsonDecode(
                  File('example/web/web/examples.json').readAsStringSync(),
                )
                as List)
            .cast<Map<String, dynamic>>();
    final example = examples.firstWhere((e) => e['id'] == 'walk');
    final vfs = await createDemoVfs({});
    final result = await pool.withSession(
      (session) => session.feedRun(example['code'] as String, os: vfs.call),
    );
    expect(result.dartValue, example['expected']);
    expect(
      (await vfs.call('Path.read_text', [
        MontyPath('/sandbox/a.csv'),
      ], {})).dartValue,
      'a,b\n1,2\n',
    );
  });

  test('staged files survive resets, while Python writes are fresh', () async {
    final staged = {'/sandbox/config.json': '{"retries":3}'};
    final first = await createDemoVfs(staged);
    final result = await pool.withSession(
      (session) => session.feedRun('''
import json
with open('/sandbox/config.json') as f:
    config = json.loads(f.read())
with open('/sandbox/output.txt', 'w') as f:
    f.write('result')
config['retries']
''', os: first.call),
    );
    expect(result.dartValue, 3);

    final fresh = await createDemoVfs(staged);
    final reset = await pool.withSession(
      (session) => session.feedRun('''
from pathlib import Path
(Path('/sandbox/config.json').read_text(), Path('/sandbox/output.txt').exists())
''', os: fresh.call),
    );
    expect(reset.dartValue, ['{"retries":3}', false]);
  });
}
