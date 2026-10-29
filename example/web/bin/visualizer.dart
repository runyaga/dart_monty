/// Algorithm Visualizer — demonstrates Monty's iterative execution by running
/// Python sorting algorithms step-by-step with animated bar chart rendering.
///
/// Each `yield_state(...)` call suspends the feed (`feedStart`); the demo
/// draws the state it carries and resumes the snapshot.
///
/// Build & run:
///   bash run.sh → open http://localhost:8088/visualizer.html
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show
        ExternalReturnValue,
        FunctionSnapshot,
        FutureSnapshot,
        MontyComplete,
        NameLookupSnapshot;

import 'package:web_example/demo_pool.dart';
import 'package:web_example/demo_ready.dart';

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
  'tim': 'Timsort',
  'shell': 'Shell Sort',
  'cocktail': 'Cocktail Sort',
  'sleep': 'Sleep Sort',
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

List<int> _generateArray(int size, {bool descending = false}) {
  if (descending) return List.generate(size, (i) => size - i);
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

/// Room for every step of the largest sort the page offers.
const _sortLimits = ResourceLimits(maxSuspensions: 100000);

Future<void> _runSort(
  Monty pool,
  String algorithm,
  String template,
  int size, {
  bool descending = false,
}) async {
  final arr = _generateArray(size, descending: descending);
  final code = template.replaceAll('INPUT_ARRAY', arr.toString());
  final name = _algorithmNames[algorithm] ?? algorithm;
  _onSortStarted(name.toJS, size.toJS);

  try {
    // The session closes when the sort ends, a suspended one included. Each
    // comparison and swap is a host call, so the session needs more than the
    // default 1000 suspensions: a 100-element bubble sort makes about 10,000.
    await pool.withSession(limits: _sortLimits, (session) async {
      var snapshot = await session.feedStart(code);
      while (snapshot is! MontyComplete) {
        if (snapshot is! FunctionSnapshot ||
            snapshot.functionName != 'yield_state') {
          // Anything else (a sleep, a pending future): the session's own
          // answer.
          snapshot = await switch (snapshot) {
            final FunctionSnapshot call => call.resumeAuto(),
            final NameLookupSnapshot lookup => lookup.resumeAuto(),
            final FutureSnapshot wait => wait.resumeAuto(),
            MontyComplete() => throw StateError('unreachable'),
          };
          continue;
        }
        final args = snapshot.args;
        final stepArr = args[0].dartValue! as List<Object?>;
        final i = args[1].dartValue! as int;
        final j = args[2].dartValue! as int;
        final action = args[3].dartValue! as String;

        _onStep(_toJsArray(stepArr), i.toJS, j.toJS, action.toJS);

        if (action == 'done') {
          _onDone(_toJsArray(stepArr));

          return;
        }

        final currentSpeed = _getSpeed().toDartInt;
        await Future<void>.delayed(Duration(milliseconds: currentSpeed));

        if (_isStopped().toDart) {
          _onStopped();

          return;
        }

        snapshot = await snapshot.resume(
          const ExternalReturnValue(MontyNone()),
        );
      }

      final value = snapshot.output.dartValue;
      _onDone(_toJsArray(value is List ? value : const []));
    });
  } on MontyError catch (e) {
    _onError('${e.exception.excType}: ${e.exception.message}'.toJS);
  } on Object catch (e) {
    _onError('Exception: $e'.toJS);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  final Monty pool;
  try {
    pool = await startDemoPool();
  } on Object catch (e) {
    _onError('Failed to start the Monty worker: $e'.toJS);
    montyDemoFailed('visualizer', 'Monty.start failed: $e');

    return;
  }

  _onReady();
  // Raised once the worker pool is up; the demo then waits for the page's
  // start button.
  montyDemoReady('visualizer');

  while (true) {
    final configJson = (await _waitForStart().toDart).toDart;
    final config = _parse(configJson);
    final algorithm = config['algorithm'] as String;
    final code = config['code'] as String;
    final size = (config['size'] as num).toInt();

    await _runSort(
      pool,
      algorithm,
      code,
      size,
      descending: config['descending'] == true,
    );
  }
}
