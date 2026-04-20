import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('BridgeEvent subclasses', () {
    test('BridgeRunStarted stores threadId and runId', () {
      const event = BridgeRunStarted(threadId: 't1', runId: 'r1');
      expect(event.threadId, 't1');
      expect(event.runId, 'r1');
      expect(event, isA<BridgeEvent>());
    });

    test('BridgeRunFinished stores all fields', () {
      const event = BridgeRunFinished(
        threadId: 't1',
        runId: 'r1',
        value: 42,
        printOutput: 'hello',
      );
      expect(event.threadId, 't1');
      expect(event.runId, 'r1');
      expect(event.value, 42);
      expect(event.printOutput, 'hello');
    });

    test('BridgeRunFinished allows null value and printOutput', () {
      const event = BridgeRunFinished(threadId: 't1', runId: 'r1');
      expect(event.value, isNull);
      expect(event.printOutput, isNull);
    });

    test('BridgeRunError stores message and optional fields', () {
      const exception = MontyException(message: 'err');
      const event = BridgeRunError(
        message: 'fail',
        printOutput: 'output',
        exception: exception,
      );
      expect(event.message, 'fail');
      expect(event.printOutput, 'output');
      expect(event.exception, exception);
    });

    test('BridgeRunError allows null optional fields', () {
      const event = BridgeRunError(message: 'fail');
      expect(event.printOutput, isNull);
      expect(event.exception, isNull);
    });

    test('BridgeCallStarted stores callId', () {
      const event = BridgeCallStarted(callId: 'c1');
      expect(event.callId, 'c1');
    });

    test('BridgeCallFinished stores callId', () {
      const event = BridgeCallFinished(callId: 'c1');
      expect(event.callId, 'c1');
    });

    test('BridgeFunctionCallStart stores callId and name', () {
      const event = BridgeFunctionCallStart(callId: 'c1', name: 'fetch');
      expect(event.callId, 'c1');
      expect(event.name, 'fetch');
    });

    test('BridgeFunctionCallArgs stores callId and delta', () {
      const event = BridgeFunctionCallArgs(callId: 'c1', delta: '{"x":1}');
      expect(event.callId, 'c1');
      expect(event.delta, '{"x":1}');
    });

    test('BridgeFunctionCallEnd stores callId', () {
      const event = BridgeFunctionCallEnd(callId: 'c1');
      expect(event.callId, 'c1');
    });

    test('BridgeFunctionCallResult stores callId and result', () {
      const event = BridgeFunctionCallResult(callId: 'c1', result: 'ok');
      expect(event.callId, 'c1');
      expect(event.result, 'ok');
    });

    test('BridgeOsCallStart stores callId and operationName', () {
      const event = BridgeOsCallStart(
        callId: 'oc1',
        operationName: 'Path.read_text',
      );
      expect(event.callId, 'oc1');
      expect(event.operationName, 'Path.read_text');
    });

    test('BridgeOsCallResult stores callId and result', () {
      const event = BridgeOsCallResult(callId: 'oc1', result: 'contents');
      expect(event.callId, 'oc1');
      expect(event.result, 'contents');
    });

    test('BridgeChildEvent wraps inner event with childHandle', () {
      const inner = BridgeRunFinished(threadId: 't1', runId: 'r1', value: 42);
      const event = BridgeChildEvent(childHandle: '3', inner: inner);
      expect(event.childHandle, '3');
      expect(event.inner, inner);
      expect(event, isA<BridgeEvent>());
    });
  });
}
