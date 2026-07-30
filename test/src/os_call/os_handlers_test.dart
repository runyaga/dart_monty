import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  OsCallHandler stubHandler(String tag) =>
      (operation, args, kwargs) async => tag;

  // monty v0.0.19 renamed this op from 'Open' to 'open' (#576). The break is
  // SILENT: a handler still keyed on the old spelling stops matching and falls
  // through with no error, so nothing fails loudly if this regresses. These two
  // tests are that loud failure.
  group('the open() op name (monty v0.0.19 rename)', () {
    test('PathOp.open is lowercase "open", not "Open"', () {
      expect(PathOp.open, 'open');
    });

    test('composeOsHandlers routes "open" to the Path. handler', () async {
      final handler = composeOsHandlers({
        'Path.': stubHandler('fs'),
        'os.': stubHandler('env'),
      });
      expect(await handler('open', ['/a.txt', 'r'], null), 'fs');

      // The old name must NOT route -- it falls through to the fallback.
      final withFallback = composeOsHandlers({
        'Path.': stubHandler('fs'),
      }, fallback: stubHandler('fallback'));
      expect(await withFallback('Open', ['/a.txt', 'r'], null), 'fallback');
    });
  });

  group('composeOsHandlers()', () {
    test('routes Path.* to filesystem handler', () async {
      final handler = composeOsHandlers({
        'Path.': stubHandler('fs'),
        'os.': stubHandler('env'),
      });

      final result = await handler('Path.exists', const [], null);
      expect(result, 'fs');
    });

    test('routes os.* to environment handler', () async {
      final handler = composeOsHandlers({
        'Path.': stubHandler('fs'),
        'os.': stubHandler('env'),
      });

      final result = await handler('os.getenv', const [], null);
      expect(result, 'env');
    });

    test('unknown prefix throws UnsupportedError', () {
      final handler = composeOsHandlers({'Path.': stubHandler('fs')});

      expect(
        () => handler('socket.connect', const [], null),
        throwsUnsupportedError,
      );
    });

    test('custom fallback handler receives unknown operations', () async {
      final handler = composeOsHandlers(
        {'Path.': stubHandler('fs')},
        fallback: stubHandler('fallback'),
      );

      final result = await handler('socket.connect', const [], null);
      expect(result, 'fallback');
    });

    test('routes date.*/datetime.* to time handler', () async {
      final time = stubHandler('time');
      final handler = composeOsHandlers({
        'Path.': stubHandler('fs'),
        'date.': time,
        'datetime.': time,
      });

      expect(await handler('date.today', const [], null), 'time');
      expect(await handler('datetime.now', const [], null), 'time');
    });

    test('multiple prefixes can map to same handler', () async {
      final shared = stubHandler('shared');
      final handler = composeOsHandlers({
        'date.': shared,
        'datetime.': shared,
      });

      expect(await handler('date.today', const [], null), 'shared');
      expect(await handler('datetime.now', const [], null), 'shared');
    });

    test('empty prefix map throws on any call', () {
      final handler = composeOsHandlers({});

      expect(
        () => handler('Path.exists', const [], null),
        throwsUnsupportedError,
      );
    });

    test('longest prefix match wins', () async {
      final broad = stubHandler('broad');
      final specific = stubHandler('specific');
      final handler = composeOsHandlers({
        'Path.': broad,
        'Path.read_': specific,
      });

      // 'Path.read_text' matches both — longest prefix wins.
      expect(await handler('Path.read_text', const [], null), 'specific');
      // 'Path.exists' only matches 'Path.'.
      expect(await handler('Path.exists', const [], null), 'broad');
    });
  });
}
