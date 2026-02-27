/// Interpreter Playground — test all Monty customization points
/// interactively in the browser.
///
/// Build & run:
///   bash run.sh → open http://localhost:8088/playground.html
///   (Windows: powershell run_playground.ps1)
library;

import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop — DartMontyBridge
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.run')
external JSPromise<JSString> _bridgeRun(
  JSString code, [
  JSString? limitsJson,
]);

@JS('DartMontyBridge.start')
external JSPromise<JSString> _bridgeStart(
  JSString code, [
  JSString? extFnsJson,
  JSString? limitsJson,
]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _bridgeResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _bridgeResumeWithError(
  JSString errorJson,
);

// ---------------------------------------------------------------------------
// JS interop — DOM callbacks defined in playground.html
// ---------------------------------------------------------------------------

@JS('onPlaygroundReady')
external void _onReady();

@JS('onPlaygroundResult')
external void _onResult(JSString resultJson);

@JS('onPlaygroundPending')
external void _onPending(JSString pendingJson);

@JS('onPlaygroundError')
external void _onError(JSString message);

@JS('waitForRun')
external JSPromise<JSString> _waitForRun();

@JS('waitForStart')
external JSPromise<JSString> _waitForStart();

@JS('waitForPendingResponse')
external JSPromise<JSString> _waitForPendingResponse();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

// ---------------------------------------------------------------------------
// Run mode — simple one-shot execution
// ---------------------------------------------------------------------------

Future<void> _handleRun(Map<String, dynamic> cfg) async {
  final code = cfg['code'] as String;
  final limits = cfg['limits'] as Map<String, dynamic>?;

  try {
    final limitsJson =
        limits != null ? jsonEncode(limits).toJS : null;
    final resultStr =
        (await _bridgeRun(code.toJS, limitsJson).toDart).toDart;
    _onResult(resultStr.toJS);
  } on Object catch (e) {
    _onError('Exception: $e'.toJS);
  }
}

// ---------------------------------------------------------------------------
// Start mode — iterative execution with external functions
// ---------------------------------------------------------------------------

Future<void> _handleStart(Map<String, dynamic> cfg) async {
  final code = cfg['code'] as String;
  final limits = cfg['limits'] as Map<String, dynamic>?;
  final extFns = cfg['extFns'] as List<dynamic>? ?? [];

  try {
    final extFnsJson =
        extFns.isNotEmpty ? jsonEncode(extFns).toJS : null;
    final limitsJson =
        limits != null ? jsonEncode(limits).toJS : null;

    var resultStr = (await _bridgeStart(
      code.toJS,
      extFnsJson,
      limitsJson,
    ).toDart)
        .toDart;

    var result = _parse(resultStr);

    if (result['ok'] != true) {
      _onError('Start failed: ${result['error']}'.toJS);
      return;
    }

    // Dispatch loop
    while (result['state'] == 'pending') {
      // Notify HTML of the pending call
      _onPending(jsonEncode({
        'function_name': result['functionName'],
        'arguments': result['args'],
        'kwargs': result['kwargs'],
        'call_id': result['callId'],
        'method_call': result['methodCall'],
      }).toJS);

      // Wait for user to respond
      final responseStr =
          (await _waitForPendingResponse().toDart).toDart;
      final response = _parse(responseStr);

      if (response['type'] == 'error') {
        final errorMsg = response['message'] as String;
        resultStr = (await _bridgeResumeWithError(
          jsonEncode(errorMsg).toJS,
        ).toDart)
            .toDart;
      } else {
        // response['value'] is a raw JSON string from the user
        final valueStr = response['value'] as String;
        resultStr =
            (await _bridgeResume(valueStr.toJS).toDart).toDart;
      }

      result = _parse(resultStr);

      if (result['ok'] != true) {
        _onError('Resume failed: ${result['error']}'.toJS);
        return;
      }
    }

    // Complete
    if (result['state'] == 'complete') {
      _onResult(jsonEncode({
        'value': result['value'],
        'error': result['error'],
        'print_output': result['printOutput'],
        'usage': result['usage'],
      }).toJS);
    }
  } on Object catch (e) {
    _onError('Exception: $e'.toJS);
  }
}

// ---------------------------------------------------------------------------
// Main — event loop waiting for user actions
// ---------------------------------------------------------------------------

Future<void> main() async {
  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    _onError('Failed to initialize Monty WASM Worker'.toJS);
    return;
  }

  _onReady();

  // Two concurrent listeners: Run and Start buttons.
  // Only one can fire at a time since the UI disables both while
  // running.
  while (true) {
    // Race: wait for either Run or Start
    final result = await Future.any([
      _waitForRun().toDart.then((s) => ('run', s.toDart)),
      _waitForStart().toDart.then((s) => ('start', s.toDart)),
    ]);

    final (mode, cfgJson) = result;
    final cfg = _parse(cfgJson);

    if (mode == 'run') {
      await _handleRun(cfg);
    } else {
      await _handleStart(cfg);
    }
  }
}
