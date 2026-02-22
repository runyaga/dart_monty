/// Algorithm Visualizer — demonstrates Monty's iterative execution by running
/// Python sorting algorithms step-by-step with animated bar chart rendering.
///
/// Build & run:
///   bash run.sh → open http://localhost:8088/visualizer.html
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

// ---------------------------------------------------------------------------
// JS interop — DartMontyBridge
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.start')
external JSPromise<JSString> _bridgeStart(
  JSString code, [
  JSString? extFnsJson,
]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _bridgeResume(JSString valueJson);

// ---------------------------------------------------------------------------
// JS interop — DOM callbacks defined in visualizer.html
// ---------------------------------------------------------------------------

@JS('onVisualizerReady')
external void _onReady();

@JS('onVisualizerStep')
external void _onStep(
  JSArray<JSNumber> arr,
  JSNumber i,
  JSNumber j,
  JSString action,
);

@JS('onVisualizerDone')
external void _onDone(JSArray<JSNumber> arr);

@JS('onVisualizerError')
external void _onError(JSString message);

@JS('onVisualizerSortStarted')
external void _onSortStarted(JSString name, JSNumber size);

@JS('waitForStart')
external JSPromise<JSString> _waitForStart();

@JS('getSpeed')
external JSNumber _getSpeed();

@JS('isStopped')
external JSBoolean _isStopped();

@JS('onVisualizerStopped')
external void _onStopped();

// ---------------------------------------------------------------------------
// Algorithm display names
// ---------------------------------------------------------------------------

const _algorithmNames = {
  'bubble': 'Bubble Sort',
  'selection': 'Selection Sort',
  'insertion': 'Insertion Sort',
  'quick': 'Quick Sort',
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

List<int> _generateArray(int size) {
  final rng = Random();
  return List.generate(size, (_) => rng.nextInt(100) + 1);
}

JSArray<JSNumber> _toJsArray(List<dynamic> list) {
  final result = <JSNumber>[];
  for (final item in list) {
    result.add((item as num).toJS);
  }
  return result.toJS;
}

// ---------------------------------------------------------------------------
// Sort runner
// ---------------------------------------------------------------------------

Future<void> _runSort(
  String algorithm,
  String template,
  int size,
  int speed,
) async {
  final arr = _generateArray(size);
  final code = template.replaceAll('INPUT_ARRAY', arr.toString());
  final name = _algorithmNames[algorithm] ?? algorithm;
  _onSortStarted(name.toJS, size.toJS);

  try {
    var result = _parse(
      (await _bridgeStart(code.toJS, '["yield_state"]'.toJS).toDart).toDart,
    );

    if (result['ok'] != true) {
      _onError('Start failed: ${result['error']}'.toJS);
      return;
    }

    while (result['state'] == 'pending') {
      final args = result['args'] as List<dynamic>;
      final stepArr = args[0] as List<dynamic>;
      final i = (args[1] as num).toInt();
      final j = (args[2] as num).toInt();
      final action = args[3] as String;

      _onStep(_toJsArray(stepArr), i.toJS, j.toJS, action.toJS);

      if (action == 'done') break;

      final currentSpeed = _getSpeed().toDartInt;
      await Future<void>.delayed(Duration(milliseconds: currentSpeed));

      if (_isStopped().toDart) {
        _onStopped();
        return;
      }

      result = _parse(
        (await _bridgeResume('null'.toJS).toDart).toDart,
      );

      if (result['ok'] != true) {
        _onError('Resume failed: ${result['error']}'.toJS);
        return;
      }
    }

    if (result['state'] == 'complete') {
      final value = result['value'];
      if (value is List) {
        _onDone(_toJsArray(value));
      } else {
        _onDone(_toJsArray([]));
      }
    }
  } on Object catch (e) {
    _onError('Exception: $e'.toJS);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    _onError('Failed to initialize Monty WASM Worker'.toJS);
    return;
  }

  _onReady();

  while (true) {
    final configJson = (await _waitForStart().toDart).toDart;
    final config = _parse(configJson);
    final algorithm = config['algorithm'] as String;
    final code = config['code'] as String;
    final size = (config['size'] as num).toInt();
    final speed = (config['speed'] as num).toInt();

    await _runSort(algorithm, code, size, speed);
  }
}
