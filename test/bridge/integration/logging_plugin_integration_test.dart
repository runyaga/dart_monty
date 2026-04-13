/// FFI integration tests for LoggingPlugin through a real AgentSession.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/logging_plugin_integration_test.dart
/// ```
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('LoggingPlugin — FFI', () {
    late LoggingPlugin logging;
    late AgentSession session;

    setUp(() {
      logging = LoggingPlugin(forwardToBridgeLogger: false);
      session = AgentSession(plugins: [logging]);
    });
    tearDown(() async => session.dispose());

    test('direct log_event_batch delivers records', () async {
      await session.execute('''
log_event_batch(batch=[
  {'level': 20, 'logger': 'app', 'message': 'hello from ffi'},
  {'level': 40, 'logger': 'app', 'message': 'error event', 'exc_info': None},
])
''');
      final logs = logging.logSignal.value;
      expect(logs, hasLength(2));
      expect(logs[0].message, 'hello from ffi');
      expect(logs[0].level, 20);
      expect(logs[1].level, 40);
    });

    // NOTE: LoggingPlugin.pythonPreamble defines a Python class (_MontyHandler)
    // which Monty's parser does not support (class definitions are not yet
    // implemented). The preamble is intended for use with full CPython runtimes
    // only. Integration tests for the preamble path are therefore omitted here.

    test('records accumulate across execute calls', () async {
      await session.execute(
        'log_event_batch(batch='
        "[{'level': 20, 'logger': 'a', 'message': 'one'}])",
      );
      await session.execute(
        'log_event_batch(batch='
        "[{'level': 20, 'logger': 'a', 'message': 'two'}])",
      );
      expect(logging.logSignal.value, hasLength(2));
    });
  });
}
