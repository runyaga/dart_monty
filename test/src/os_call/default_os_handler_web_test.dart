// The web default handler: an in-memory filesystem for `Path.*`, no `os.*`, and
// no clock routing. Imported directly so the VM can run it.
import 'package:dart_monty/src/os_call/default_os_handler_web.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_os_call.dart';

void main() {
  test('Path.* is an in-memory VFS that starts empty', () {
    final handler = defaultOsHandler();

    expect(rawCall(handler, 'Path.exists', ['/a.txt']), const MontyBool(false));
    expect(
      rawCall(handler, 'Path.write_text', ['/a.txt', 'hi']),
      const MontyInt(2),
    );
    expect(
      rawCall(handler, 'Path.read_text', ['/a.txt']),
      const MontyString('hi'),
    );
  });

  test('each call to defaultOsHandler gets its own VFS', () {
    expect(
      rawCall(defaultOsHandler(), 'Path.write_text', ['/a.txt', 'hi']),
      const MontyInt(2),
    );

    expect(
      rawCall(defaultOsHandler(), 'Path.exists', ['/a.txt']),
      const MontyBool(false),
    );
  });

  test('open() reaches the in-memory VFS', () {
    final handler = defaultOsHandler();
    expect(
      rawCall(handler, 'Path.write_text', ['/a.txt', 'hi']),
      const MontyInt(2),
    );

    expect(rawCall(handler, 'open', ['/a.txt', 'r']), isA<MontyFileHandle>());
  });

  for (final op in [
    'os.getenv',
    'os.environ',
    'date.today',
    'datetime.now',
    'socket.connect',
  ]) {
    test('$op is declined synchronously (no env, no clock)', () {
      expectSyncDecline(() => rawCall(defaultOsHandler(), op, ['PATH']));
    });
  }
}
