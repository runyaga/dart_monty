// Integration: open()/file I/O and typed OS exceptions through MontyRuntime.
//
// monty v0.0.18's open() routes its `Open` OS-call to the filesystem handler
// backing `Path.*` (here OSAccess with application policy), and OS
// errors reach Python as their real class.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MemoryFile, MontyFileHandle;
import 'package:dart_monty_core/dart_monty_core.dart' show OSAccess;
import 'package:test/test.dart';

import '_worker.dart';

void main() {
  late Monty pool;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  group('open() / file I/O', () {
    test('write, with open(...), append, and read back', () async {
      final rt = await MontyRuntime.start(
        pool: pool,
        osHandlers: {'Path.': OSAccess().call},
      );
      addTearDown(rt.dispose);

      await rt.execute(r'''
with open('/notes.txt', 'w') as f:
    f.write('a\n')
    f.write('b\n')
with open('/notes.txt', 'a') as f:
    f.write('c\n')
''').result;

      final r = await rt.execute('''
f = open('/notes.txt')
text = f.read()
f.close()
text
''').result;
      expect(r.dartValue, 'a\nb\nc\n');
    });

    test('binary round-trip is byte-faithful', () async {
      final rt = await MontyRuntime.start(
        pool: pool,
        osHandlers: {'Path.': OSAccess().call},
      );
      addTearDown(rt.dispose);

      final r = await rt.execute(r'''
with open('/b.bin', 'wb') as f:
    f.write(b'\x00\x01\x02\xff')
with open('/b.bin', 'rb') as f:
    data = f.read()
list(data)
''').result;
      expect(r.dartValue, [0, 1, 2, 255]);
    });

    test('open() returns a MontyFileHandle', () async {
      final rt = await MontyRuntime.start(
        pool: pool,
        osHandlers: {'Path.': OSAccess().call},
      );
      addTearDown(rt.dispose);

      await rt.execute("open('/x.txt', 'w').write('hi')").result;
      final r = await rt.execute("open('/x.txt')").result;
      expect(r, isA<MontyFileHandle>());
      expect((r as MontyFileHandle).mode, 'r');
    });

    test('missing file raises a catchable FileNotFoundError', () async {
      final rt = await MontyRuntime.start(
        pool: pool,
        osHandlers: {'Path.': OSAccess().call},
      );
      addTearDown(rt.dispose);

      final r = await rt.execute('''
try:
    open('/nope.txt')
    out = 'no-error'
except FileNotFoundError:
    out = 'caught'
out
''').result;
      expect(r.dartValue, 'caught');
    });

    test(
      'write to a read-only handler raises a catchable PermissionError',
      () async {
        final roFs = OSAccess(files: [MemoryFile('/secret.txt', 'sk-1')]);
        final rt = await MontyRuntime.start(
          pool: pool,
          osHandlers: {
            'Path.': (name, args, kwargs) {
              if (name == 'open' &&
                  args.length > 1 &&
                  args[1].dartValue != 'r') {
                throw const ExternalException(
                  'PermissionError',
                  'Read-only application '
                      'data',
                );
              }
              return roFs.call(name, args, kwargs);
            },
          },
        );
        addTearDown(rt.dispose);

        final r = await rt.execute('''
try:
    open('/secret.txt', 'w')
    out = 'no-error'
except PermissionError:
    out = 'caught'
out
''').result;
        expect(r.dartValue, 'caught');
      },
    );
  });
}
