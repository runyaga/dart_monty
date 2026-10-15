// Which failures replace a shared runtime's held session, on a real worker.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';

void main() {
  late Monty pool;
  late MontyRuntime runtime;

  setUp(() async {
    pool = await startTestPool();
    addTearDown(pool.close);
    runtime = await MontyRuntime.start(pool: pool);
    addTearDown(runtime.dispose);
    await runtime.execute('kept = 1').result;
  });

  Future<String> excTypeOf(String code) async {
    try {
      await runtime.execute(code).result;
    } on MontyError catch (e) {
      return e.exception.excType;
    }
    fail('$code did not raise');
  }

  for (final type in ['TimeoutError', 'MemoryError']) {
    test('an uncaught $type the code raises itself also replaces the '
        'session: the next execution has empty globals', () async {
      expect(await excTypeOf('raise $type("mine")'), type);

      expect(await excTypeOf('kept'), 'NameError');
      expect((await runtime.execute('1 + 1').result).dartValue, 2);
    });

    test('a $type the code catches keeps the session', () async {
      await runtime
          .execute('try:\n  raise $type()\nexcept $type:\n  pass')
          .result;

      expect((await runtime.execute('kept').result).dartValue, 1);
    });
  }

  test('any other uncaught error keeps the session', () async {
    expect(await excTypeOf('raise ValueError("x")'), 'ValueError');

    expect((await runtime.execute('kept').result).dartValue, 1);
  });
}
