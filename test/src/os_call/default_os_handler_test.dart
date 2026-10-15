// defaultOsHandler on a native (`dart:io`) platform: an `OsHandler` over the
// host filesystem and environment, with no clock routing and a synchronous
// decline for everything else.
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_os_call.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('d15_default_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test("is core's OsHandler: MontyValue in, MontyValue out", () {
    expect(defaultOsHandler, isA<OsHandler Function()>());
    expect(
      defaultOsHandler()('os.getenv', const [MontyString('PATH')], const {}),
      isA<MontyValue>(),
    );
  });

  test('the barrel selects the native branch when dart:io is present', () {
    // Native is the only branch with a host environment.
    final result = rawCall(defaultOsHandler(), 'os.getenv', ['PATH']);

    expect(result, MontyValue.fromDart(Platform.environment['PATH']));
  });

  group('Path.* goes to the local filesystem with full access', () {
    test('write, read and exists agree with dart:io', () {
      final path = '${tmp.path}/note.txt';
      final handler = defaultOsHandler();

      expect(
        rawCall(handler, 'Path.write_text', [path, 'hello']),
        const MontyInt(5),
      );
      expect(File(path).readAsStringSync(), 'hello');
      expect(
        rawCall(handler, 'Path.read_text', [path]),
        const MontyString('hello'),
      );
      expect(rawCall(handler, 'Path.exists', [path]), const MontyBool(true));
    });

    test('kwargs arrive as a map and a None result is MontyNone', () {
      final path = '${tmp.path}/a/b/c';
      final handler = defaultOsHandler();

      final result = rawCall(
        handler,
        'Path.mkdir',
        [path],
        {'parents': true, 'exist_ok': true},
      );

      expect(result, const MontyNone());
      expect(Directory(path).existsSync(), isTrue);
    });

    test('an empty kwargs map is accepted, never null', () {
      final handler = defaultOsHandler();

      expect(
        rawCall(handler, 'Path.exists', ['${tmp.path}/nope']),
        const MontyBool(false),
      );
    });

    test('open() is routed to the Path handler', () {
      final path = '${tmp.path}/o.txt';
      File(path).writeAsStringSync('x');

      final result = rawCall(defaultOsHandler(), 'open', [path, 'r']);

      expect(result, isA<MontyFileHandle>());
    });

    test('a host failure is an ExternalException with the CPython type', () {
      expect(
        () => rawCall(defaultOsHandler(), 'Path.read_text', [
          '${tmp.path}/missing',
        ]),
        throwsA(
          isA<ExternalException>().having(
            (e) => e.excType,
            'excType',
            'FileNotFoundError',
          ),
        ),
      );
    });

    test('a directory write maps to IsADirectoryError', () {
      expect(
        () => rawCall(defaultOsHandler(), 'Path.write_text', [tmp.path, 'x']),
        throwsA(
          isA<ExternalException>().having(
            (e) => e.excType,
            'excType',
            'IsADirectoryError',
          ),
        ),
      );
    });
  });

  group('os.* goes to the host environment', () {
    test('os.getenv matches the process environment', () {
      final handler = defaultOsHandler();
      final key = Platform.environment.keys.first;

      expect(
        rawCall(handler, 'os.getenv', [key]),
        MontyValue.fromDart(Platform.environment[key]),
      );
      expect(
        rawCall(handler, 'os.getenv', ['D15_NOT_SET_ANYWHERE', 'dflt']),
        const MontyString('dflt'),
      );
      expect(
        rawCall(handler, 'os.getenv', ['D15_NOT_SET_ANYWHERE']),
        const MontyNone(),
      );
    });

    test('os.environ is the whole host environment', () {
      final result = rawCall(defaultOsHandler(), 'os.environ');

      expect(
        lowerOsResult(result as MontyValue),
        Map<String, Object?>.of(Platform.environment),
      );
    });
  });

  group('everything else declines synchronously', () {
    // The clock is NOT routed here: under the default OsPolicy the worker's
    // own `system` clock answers (DM1, upstream behaviour), so a call that
    // does reach the handler is not one dm answers.
    for (final op in [
      'date.today',
      'datetime.now',
      'time.monotonic',
      'Path.stat',
      'socket.connect',
    ]) {
      test(op, () {
        expectSyncDecline(() => rawCall(defaultOsHandler(), op));
      });
    }
  });
}
