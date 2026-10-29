@Tags(['integration'])
@TestOn('vm')
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

// Follow vfs_demo_test.dart: exercise shared browser setup on the VM without
// importing the JS entrypoint or adding the nested example as a dependency.
// ignore: avoid_relative_lib_imports
import '../../example/web/lib/repl_session.dart';
import '_worker.dart';

void main() {
  late Monty pool;
  setUpAll(() async {
    pool = await startTestPool();
    addTearDown(pool.close);
  });

  test('REPL files persist across runs and Reset starts empty', () async {
    final session = await ReplDemoSession.start(pool);
    addTearDown(session.dispose);
    await session.runtime.execute('''
import csv
with open('output.csv', mode='w', newline='', encoding='utf-8') as file:
    csv.writer(file).writerows([["Name","Age"],["Alice",30]])
''').result;

    final read = await session.runtime.execute('''
with open('output.csv', newline='', encoding='utf-8') as file:
    rows = list(csv.reader(file))
from pathlib import Path
import os
[rows, os.getcwd(), Path('/work/output.csv').is_file()]
''').result;
    expect(read.dartValue, [
      [
        ['Name', 'Age'],
        ['Alice', '30'],
      ],
      '/work',
      true,
    ]);

    await session.reset();
    final fresh = await session.runtime.execute('''
import os
from pathlib import Path
try:
    rows
    kept = True
except NameError:
    kept = False
[os.getcwd(), list(Path('.').iterdir()), kept]
''').result;
    expect(fresh.dartValue, ['/work', <Object?>[], false]);
    await session.runtime.execute('''
with open('fresh.txt', 'w') as file:
    file.write('fresh')
assert Path('/work/fresh.txt').read_text() == 'fresh'
''').result;
  });
}
