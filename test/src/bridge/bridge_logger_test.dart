import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/bridge/struct_log_logger.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

/// A consumer logger that counts its calls.
final class _CountingLogger implements BridgeLogger {
  int messages = 0;
  int closes = 0;

  @override
  void trace(String message, {Map<String, Object?>? attributes}) => messages++;

  @override
  void debug(String message, {Map<String, Object?>? attributes}) => messages++;

  @override
  void info(String message, {Map<String, Object?>? attributes}) => messages++;

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) => messages++;

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) => messages++;

  @override
  BridgeLogger child(String name) => this;

  @override
  void close() => closes++;
}

void main() {
  late MemorySink sink;
  late LogLevel previousLevel;

  setUp(() {
    sink = MemorySink();
    previousLevel = LogManager.instance.minimumLevel;
    LogManager.instance
      ..addSink(sink)
      ..minimumLevel = LogLevel.trace;
  });

  tearDown(() {
    LogManager.instance
      ..removeSink(sink)
      ..minimumLevel = previousLevel;
  });

  /// Runs one execution that calls a host function on a bridge with
  /// [logger], then disposes the bridge.
  Future<void> runOnce(BridgeLogger? logger) async {
    final fake = FakeMontySession()
      ..willCall('f')
      ..willReturn(const MontyNone());
    final bridge = MontyBridge(session: fake, logger: logger)
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'f'),
          handler: (args, ctx) async => null,
        ),
      );
    await bridge.execute('f()').toList();
    bridge.dispose();
  }

  group('BridgeLogger.silent', () {
    test('discards every message, is its own child, and close is a no-op', () {
      const silent = BridgeLogger.silent;

      silent
        ..trace('t')
        ..debug('d')
        ..info('i')
        ..warning('w')
        ..error('e')
        ..close()
        ..info('after close');

      expect(silent.child('x'), same(silent));
      expect(sink.records, isEmpty);
    });

    test('silences a bridge: nothing reaches struct_log', () async {
      await runOnce(BridgeLogger.silent);

      expect(sink.records, isEmpty);
    });
  });

  group("dm's default logger", () {
    test('a null logger logs through struct_log under monty', () async {
      await runOnce(null);

      expect(sink.records, isNotEmpty);
      expect(sink.records.map((r) => r.loggerName).toSet(), {'monty'});
    });

    test('child(name) is <parent>.<name>', () {
      StructLogBridgeLogger.root(
        LogManager.instance,
      ).child('a').child('b').info('hi');

      expect(sink.records.single.loggerName, 'monty.a.b');
    });

    test('close silences the logger and every child it made', () {
      final root = StructLogBridgeLogger.root(LogManager.instance);
      final child = root.child('c');

      root
        ..close()
        ..info('root');
      child.info('child');

      expect(sink.records, isEmpty);
      expect(root.child('late'), same(BridgeLogger.silent));
    });
  });

  group("the bridge's use of its logger", () {
    test('maps run lifecycle to info and calls to debug/trace', () async {
      await runOnce(null);

      final levels = sink.records.map((r) => r.level).toSet();
      expect(levels, containsAll([LogLevel.info, LogLevel.debug]));
      expect(
        sink.records.where((r) => r.level == LogLevel.warning),
        isEmpty,
      );
    });

    test("dispose closes a consumer's logger", () async {
      final logger = _CountingLogger();

      await runOnce(logger);

      expect(logger.messages, greaterThan(0));
      expect(logger.closes, 1);
    });
  });
}
