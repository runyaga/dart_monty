// A host OS handler that DECLINES must produce the call's documented default,
// not leak the Dart exception's class name into Python.
//
// WHY THIS IS AN INTEGRATION TEST AND NOT A UNIT TEST. The decline path ends in
// `resumeWithException`, and `MockMontyPlatform` does not implement that method
// at all — it has `resume`, `resumeWithError` and `resumeAsFuture` only. A
// mock-based test cannot reach this arm; it stalls with the run never
// finishing. That gap also means the pre-existing typed-exception arm
// (`on OsCallException` -> resumeWithException) has no mock coverage either.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a declining OS handler yields the call default, not a Dart type name',
    () async {
      final rt = MontyRuntime(
        os: (op, args, kwargs) async => throw OsCallNotHandledException(op),
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
      final out = result.value.dartValue! as String;

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
        reason:
            'osCallNoHandlerDefault refuses an unhandled open() with '
            'PermissionError',
      );
    },
  );
}
