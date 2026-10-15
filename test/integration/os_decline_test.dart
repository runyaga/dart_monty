// A host OS handler that DECLINES must produce the call's documented default,
// not leak the Dart exception's class name into Python.
//
// On core 0.110 a decline is a synchronous throw of OsCallNotHandledException,
// and the worker computes the default: PermissionError for a filesystem call.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';
import '_worker.dart';

void main() {
  late Monty pool;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  test(
    'a declining OS handler yields the call default, not a Dart type name',
    () async {
      final rt = await MontyRuntime.start(
        pool: pool,
        os: (op, args, kwargs) => throw const OsCallNotHandledException(),
      );
      addTearDown(rt.dispose);

      final handle = rt.execute('''
try:
    open('/nope.txt').read()
    out = 'NO EXCEPTION RAISED'
except Exception as e:
    out = type(e).__name__ + ': ' + str(e)
out
''');
      final result = await handle.result;
      final out = result.dartValue! as String;

      // Before the fix this was:
      //   RuntimeError: OsCallNotHandledException(open)
      // i.e. the Dart exception's toString leaking into the sandbox.
      expect(
        out,
        isNot(contains('OsCallNotHandledException')),
        reason: 'a Dart exception class name must never reach Python',
      );
      expect(
        out,
        startsWith('PermissionError'),
        reason: 'the worker refuses a declined open() with PermissionError',
      );
    },
  );
}
