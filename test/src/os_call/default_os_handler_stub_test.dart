// The stub default handler, for platforms with neither `dart:io` nor
// `dart:js_interop`: every call is declined, synchronously.
import 'package:dart_monty/src/os_call/default_os_handler_stub.dart';
import 'package:test/test.dart';

import '_os_call.dart';

void main() {
  for (final op in [
    'Path.exists',
    'open',
    'os.getenv',
    'os.environ',
    'datetime.now',
    'socket.connect',
  ]) {
    test('$op is declined synchronously', () {
      expectSyncDecline(() => rawCall(defaultOsHandler(), op, ['x']));
    });
  }
}
