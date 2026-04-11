import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  MontyOsCall fakeOsCall(String op) =>
      MontyOsCall(operationName: op, arguments: const []);

  group('RouterOsCallHandler', () {
    test('routes Path.* to filesystem handler', () async {
      final router = RouterOsCallHandler({
        'Path.': _StubHandler('fs'),
        'os.': _StubHandler('env'),
      });

      final result = await router.handle(fakeOsCall('Path.exists'));
      expect(result, 'fs');
    });

    test('routes os.* to environment handler', () async {
      final router = RouterOsCallHandler({
        'Path.': _StubHandler('fs'),
        'os.': _StubHandler('env'),
      });

      final result = await router.handle(fakeOsCall('os.getenv'));
      expect(result, 'env');
    });

    test('unknown prefix throws UnsupportedError', () {
      final router = RouterOsCallHandler({'Path.': _StubHandler('fs')});

      expect(
        () => router.handle(fakeOsCall('socket.connect')),
        throwsUnsupportedError,
      );
    });

    test('custom fallback handler receives unknown operations', () async {
      final router = RouterOsCallHandler({
        'Path.': _StubHandler('fs'),
      }, fallback: _StubHandler('fallback'));

      final result = await router.handle(fakeOsCall('socket.connect'));
      expect(result, 'fallback');
    });

    test('dispose() disposes all child handlers', () async {
      final fs = _StubHandler('fs');
      final env = _StubHandler('env');
      final fallback = _StubHandler('fallback');
      final router = RouterOsCallHandler({
        'Path.': fs,
        'os.': env,
      }, fallback: fallback);

      await router.dispose();

      expect(fs.disposed, isTrue);
      expect(env.disposed, isTrue);
      expect(fallback.disposed, isTrue);
    });

    test('routes date.*/datetime.* to time handler', () async {
      final time = _StubHandler('time');
      final router = RouterOsCallHandler({
        'Path.': _StubHandler('fs'),
        'date.': time,
        'datetime.': time,
      });

      expect(await router.handle(fakeOsCall('date.today')), 'time');
      expect(await router.handle(fakeOsCall('datetime.now')), 'time');
    });

    test('multiple prefixes can map to same handler', () async {
      final shared = _StubHandler('shared');
      final router = RouterOsCallHandler({
        'date.': shared,
        'datetime.': shared,
      });

      // Both should work and share the same handler.
      expect(await router.handle(fakeOsCall('date.today')), 'shared');
      expect(await router.handle(fakeOsCall('datetime.now')), 'shared');

      // Dispose should only be called once despite two prefix entries.
      await router.dispose();
      expect(shared.disposeCount, 1);
    });

    test('empty prefix map throws on any call', () {
      final router = RouterOsCallHandler({});

      expect(
        () => router.handle(fakeOsCall('Path.exists')),
        throwsUnsupportedError,
      );
    });

    test('longest prefix match wins', () async {
      final broad = _StubHandler('broad');
      final specific = _StubHandler('specific');
      final router = RouterOsCallHandler({
        'Path.': broad,
        'Path.read_': specific,
      });

      // 'Path.read_text' matches both — longest prefix wins.
      expect(await router.handle(fakeOsCall('Path.read_text')), 'specific');
      // 'Path.exists' only matches 'Path.'.
      expect(await router.handle(fakeOsCall('Path.exists')), 'broad');
    });

    test('handlerFor returns registered handler', () {
      final fs = _StubHandler('fs');
      final router = RouterOsCallHandler({'Path.': fs});

      expect(router.handlerFor('Path.'), same(fs));
      expect(router.handlerFor('os.'), isNull);
    });

    test('dispose() with empty handlers map does not throw', () async {
      final router = RouterOsCallHandler({});
      await router.dispose();
    });
  });
}

class _StubHandler extends OsCallHandler {
  _StubHandler(this.tag);

  final String tag;
  bool disposed = false;
  int disposeCount = 0;

  @override
  Future<Object?> handle(MontyOsCall call) => Future.value(tag);

  @override
  Future<void> dispose() async {
    disposed = true;
    disposeCount++;
  }
}
