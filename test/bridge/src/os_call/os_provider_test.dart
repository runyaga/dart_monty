import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:test/test.dart';

void main() {
  MontyOsCall fakeOsCall(String op) =>
      MontyOsCall(operationName: op, arguments: const []);

  group('OsProvider.compose()', () {
    test('routes Path.* to filesystem provider', () async {
      final provider = OsProvider.compose({
        'Path.': _StubProvider('fs'),
        'os.': _StubProvider('env'),
      });

      final result = await provider.resolve(fakeOsCall('Path.exists'));
      expect(result, 'fs');
    });

    test('routes os.* to environment provider', () async {
      final provider = OsProvider.compose({
        'Path.': _StubProvider('fs'),
        'os.': _StubProvider('env'),
      });

      final result = await provider.resolve(fakeOsCall('os.getenv'));
      expect(result, 'env');
    });

    test('unknown prefix throws UnsupportedError', () {
      final provider = OsProvider.compose({'Path.': _StubProvider('fs')});

      expect(
        () => provider.resolve(fakeOsCall('socket.connect')),
        throwsUnsupportedError,
      );
    });

    test('custom fallback provider receives unknown operations', () async {
      final provider = OsProvider.compose({
        'Path.': _StubProvider('fs'),
      }, fallback: _StubProvider('fallback'));

      final result = await provider.resolve(fakeOsCall('socket.connect'));
      expect(result, 'fallback');
    });

    test('dispose() disposes all child providers', () async {
      final fs = _StubProvider('fs');
      final env = _StubProvider('env');
      final fallback = _StubProvider('fallback');
      final provider = OsProvider.compose({
        'Path.': fs,
        'os.': env,
      }, fallback: fallback);

      await provider.dispose();

      expect(fs.disposed, isTrue);
      expect(env.disposed, isTrue);
      expect(fallback.disposed, isTrue);
    });

    test('routes date.*/datetime.* to time provider', () async {
      final time = _StubProvider('time');
      final provider = OsProvider.compose({
        'Path.': _StubProvider('fs'),
        'date.': time,
        'datetime.': time,
      });

      expect(await provider.resolve(fakeOsCall('date.today')), 'time');
      expect(await provider.resolve(fakeOsCall('datetime.now')), 'time');
    });

    test('multiple prefixes can map to same provider', () async {
      final shared = _StubProvider('shared');
      final provider = OsProvider.compose({
        'date.': shared,
        'datetime.': shared,
      });

      // Both should work and share the same provider.
      expect(await provider.resolve(fakeOsCall('date.today')), 'shared');
      expect(await provider.resolve(fakeOsCall('datetime.now')), 'shared');

      // Dispose should only be called once despite two prefix entries.
      await provider.dispose();
      expect(shared.disposeCount, 1);
    });

    test('empty prefix map throws on any call', () {
      final provider = OsProvider.compose({});

      expect(
        () => provider.resolve(fakeOsCall('Path.exists')),
        throwsUnsupportedError,
      );
    });

    test('longest prefix match wins', () async {
      final broad = _StubProvider('broad');
      final specific = _StubProvider('specific');
      final provider = OsProvider.compose({
        'Path.': broad,
        'Path.read_': specific,
      });

      // 'Path.read_text' matches both — longest prefix wins.
      expect(await provider.resolve(fakeOsCall('Path.read_text')), 'specific');
      // 'Path.exists' only matches 'Path.'.
      expect(await provider.resolve(fakeOsCall('Path.exists')), 'broad');
    });

    test('providerFor returns registered provider', () {
      final fs = _StubProvider('fs');
      final provider = OsProvider.compose({'Path.': fs});

      expect(provider.providerFor('Path.'), same(fs));
      expect(provider.providerFor('os.'), isNull);
    });

    test('dispose() with empty providers map does not throw', () async {
      final provider = OsProvider.compose({});
      await provider.dispose();
    });
  });
}

class _StubProvider extends OsProvider {
  _StubProvider(this.tag) : super.base();

  final String tag;
  bool disposed = false;
  int disposeCount = 0;

  @override
  Future<Object?> resolve(MontyOsCall call) => Future.value(tag);

  @override
  Future<void> dispose() async {
    disposed = true;
    disposeCount++;
  }
}
