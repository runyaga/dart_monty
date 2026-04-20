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

    test('BridgeStepStarted stores stepId', () {
      const event = BridgeStepStarted(stepId: 's1');
      expect(event.stepId, 's1');
    });

    test('BridgeStepFinished stores stepId', () {
      const event = BridgeStepFinished(stepId: 's1');
      expect(event.stepId, 's1');
    });

    test('BridgeToolCallStart stores callId and name', () {
      const event = BridgeToolCallStart(callId: 'c1', name: 'fetch');
      expect(event.callId, 'c1');
      expect(event.name, 'fetch');
    });

    test('BridgeToolCallArgs stores callId and delta', () {
      const event = BridgeToolCallArgs(callId: 'c1', delta: '{"x":1}');
      expect(event.callId, 'c1');
      expect(event.delta, '{"x":1}');
    });

    test('BridgeToolCallEnd stores callId', () {
      const event = BridgeToolCallEnd(callId: 'c1');
      expect(event.callId, 'c1');
    });

    test('BridgeToolCallResult stores callId and result', () {
      const event = BridgeToolCallResult(callId: 'c1', result: 'ok');
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
