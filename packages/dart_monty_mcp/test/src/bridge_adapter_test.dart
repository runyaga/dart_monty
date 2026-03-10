import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

void main() {
  group('bridgeEventsToResult', () {
    test('returns value on successful finish', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
        const BridgeRunFinished(
          threadId: '0',
          runId: '1',
          value: 42,
        ),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(result.isError, isFalse);
      expect(_text(result), '42');
    });

    test('returns stdout output', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
        const BridgeTextStart(messageId: '2'),
        const BridgeTextContent(messageId: '2', delta: 'hello world\n'),
        const BridgeTextEnd(messageId: '2'),
        const BridgeRunFinished(threadId: '0', runId: '1'),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(result.isError, isFalse);
      expect(_text(result), 'hello world');
    });

    test('combines stdout and return value', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
        const BridgeTextStart(messageId: '2'),
        const BridgeTextContent(messageId: '2', delta: 'output\n'),
        const BridgeTextEnd(messageId: '2'),
        const BridgeRunFinished(
          threadId: '0',
          runId: '1',
          value: 99,
        ),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(_text(result), 'output\n99');
    });

    test('returns error on BridgeRunError', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
        const BridgeRunError(message: 'NameError: x is not defined'),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(result.isError, isTrue);
      expect(_text(result), 'NameError: x is not defined');
    });

    test('includes stdout in error result', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
        const BridgeTextStart(messageId: '2'),
        const BridgeTextContent(messageId: '2', delta: 'partial\n'),
        const BridgeTextEnd(messageId: '2'),
        const BridgeRunError(message: 'crash'),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(result.isError, isTrue);
      expect(_text(result), 'partial\ncrash');
    });

    test('returns (no output) when finish has no value or output', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
        const BridgeRunFinished(threadId: '0', runId: '1'),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(result.isError, isFalse);
      expect(_text(result), '(no output)');
    });

    test('returns error when stream ends without finish', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(result.isError, isTrue);
      expect(_text(result), 'Execution ended without result');
    });

    test('ignores step/tool events', () async {
      final events = Stream<BridgeEvent>.fromIterable([
        const BridgeRunStarted(threadId: '0', runId: '1'),
        const BridgeStepStarted(stepId: 'fn'),
        const BridgeToolCallStart(callId: '2', name: 'fn'),
        const BridgeToolCallArgs(callId: '2', delta: '{}'),
        const BridgeToolCallEnd(callId: '2'),
        const BridgeToolCallResult(callId: '2', result: 'ok'),
        const BridgeStepFinished(stepId: 'fn'),
        const BridgeRunFinished(threadId: '0', runId: '1', value: 'done'),
      ]);

      final result = await bridgeEventsToResult(events);

      expect(result.isError, isFalse);
      expect(_text(result), 'done');
    });
  });
}

String _text(CallToolResult result) =>
    (result.content.first as TextContent).text;
