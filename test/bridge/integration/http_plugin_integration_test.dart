/// FFI integration tests for HttpPlugin through a real AgentSession.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/http_plugin_integration_test.dart
/// ```
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

const _testUrl = 'https://demo.toughserv.com/api/v1/installation/versions';

void main() {
  group(
    'HttpPlugin — FFI',
    () {
      late HttpPlugin http;
      late AgentSession session;

      setUp(() {
        http = HttpPlugin();
        session = AgentSession(plugins: [http]);
      });
      tearDown(() async => session.dispose());

      test('http_get returns ok response', () async {
        final r = await session.execute("http_get(url='$_testUrl')");
        expect(r.error, isNull);
        final result = r.value.dartValue! as Map;
        expect(result['ok'], isTrue);
        expect(result['status_code'], 200);
        expect(result['text'], isA<String>());
      });

      test('http_get result accessible as Python dict', () async {
        final r = await session.execute('''
resp = http_get(url='$_testUrl')
resp['ok']
''');
        expect(r.error, isNull);
        expect(r.value.dartValue, true);
      });

      test('totalRequestsSignal increments per call', () async {
        expect(http.totalRequestsSignal.value, 0);
        await session.execute("http_get(url='$_testUrl')");
        expect(http.totalRequestsSignal.value, 1);
        await session.execute("http_get(url='$_testUrl')");
        expect(http.totalRequestsSignal.value, 2);
      });

      test('totalBytesDownloadedSignal increases', () async {
        expect(http.totalBytesDownloadedSignal.value, 0);
        await session.execute("http_get(url='$_testUrl')");
        expect(http.totalBytesDownloadedSignal.value, greaterThan(0));
      });

      test('unreachable host surfaces an error', () async {
        final r = await session.execute(
          "http_get(url='http://localhost:19999')",
        );
        final isError =
            r.error != null ||
            (r.value.dartValue is Map &&
                (r.value.dartValue! as Map)['ok'] == false);
        expect(isError, isTrue, reason: 'unreachable host must surface error');
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
