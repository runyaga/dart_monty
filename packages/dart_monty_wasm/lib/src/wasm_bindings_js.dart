import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_monty_wasm/src/wasm_bindings.dart';

/// JS interop extension type for the raw snapshot result object.
///
/// The bridge returns a plain JS object `{ ok, snapshotBuffer?, error? }`
/// instead of a JSON string, because `JSON.stringify(ArrayBuffer)` returns
/// `{}` — binary data would be silently lost.
extension type _SnapshotResult._(JSObject _) implements JSObject {
  external JSBoolean get ok;
  external JSString? get error;
  external JSArrayBuffer? get snapshotBuffer;
}

// ---------------------------------------------------------------------------
// JS interop for instance-based DartMontyBridge
// ---------------------------------------------------------------------------

/// Binds to the JS `DartMontyBridge` class exposed on `window`.
///
/// Each instance manages its own Worker for session isolation.
/// Instance fields (not static) prevent cross-session promise routing bugs
/// when multiple WASM sessions exist concurrently.
@JS('DartMontyBridge')
extension type JsDartMontyBridge._(JSObject _) implements JSObject {
  /// Creates a new JS `DartMontyBridge` instance with its own Worker.
  external JsDartMontyBridge();

  /// Initializes the Worker and loads the WASM module.
  external JSPromise<JSBoolean> init();

  /// Runs Python [code] to completion.
  external JSPromise<JSString> run(
    JSString code, [
    JSString? limitsJson,
    JSString? scriptName,
  ]);

  /// Starts iterative execution of [code] with optional external functions.
  external JSPromise<JSString> start(
    JSString code, [
    JSString? extFnsJson,
    JSString? limitsJson,
    JSString? scriptName,
  ]);

  /// Resumes paused execution with [valueJson].
  external JSPromise<JSString> resume(JSString valueJson);

  /// Resumes paused execution by injecting an error.
  external JSPromise<JSString> resumeWithError(JSString errorJson);

  /// Captures the current interpreter state as a binary snapshot.
  external JSPromise<JSAny> snapshot();

  /// Restores interpreter state from a base64-encoded snapshot.
  external JSPromise<JSString> restore(JSString dataBase64);

  /// Returns JSON describing the bridge state.
  external JSString discover();

  /// Terminates the Worker and rejects pending promises.
  external JSPromise<JSString> cancel();

  /// Disposes the Worker session, rejecting pending promises first.
  external JSPromise<JSString> dispose();
}

/// Concrete [WasmBindings] implementation using `dart:js_interop`.
///
/// Each instance holds its own [JsDartMontyBridge] JS object, which in turn
/// manages its own Web Worker hosting the @pydantic/monty WASM runtime.
class WasmBindingsJs extends WasmBindings {
  /// Creates a [WasmBindingsJs].
  WasmBindingsJs();

  late final JsDartMontyBridge _bridge = JsDartMontyBridge();

  @override
  Future<bool> init() async {
    final result = await _bridge.init().toDart;

    return result.toDart;
  }

  @override
  Future<int> createSession() async {
    // Instance-based bridge: each WasmBindingsJs IS a session.
    // Return a synthetic ID; real session routing is per-bridge-instance.
    return 1;
  }

  @override
  Future<void> disposeSession(int sessionId) async {
    // No-op: instance-based bridge handles cleanup in dispose().
  }

  @override
  Future<WasmRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async {
    final resultJson =
        await _bridge.run(code.toJS, limitsJson?.toJS, scriptName?.toJS).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    final rawTraceback = map['traceback'] as List<Object?>?;

    return WasmRunResult(
      ok: map['ok'] as bool,
      value: map['value'],
      printOutput: map['print_output'] as String?,
      error: map['error'] as String?,
      errorType: map['errorType'] as String?,
      excType: map['excType'] as String?,
      traceback: rawTraceback,
    );
  }

  @override
  Future<WasmProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async {
    final resultJson = await _bridge
        .start(code.toJS, extFnsJson?.toJS, limitsJson?.toJS, scriptName?.toJS)
        .toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resume(String valueJson) async {
    final resultJson = await _bridge.resume(valueJson.toJS).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resumeWithError(String errorMessage) async {
    final errorJson = json.encode(errorMessage);
    final resultJson = await _bridge.resumeWithError(errorJson.toJS).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resumeAsFuture() async {
    throw UnsupportedError(
      'resumeAsFuture() is not supported in the WASM backend.',
    );
  }

  @override
  Future<WasmProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async {
    throw UnsupportedError(
      'resolveFutures() is not supported in the WASM backend.',
    );
  }

  @override
  Future<Uint8List> snapshot() async {
    final jsAny = await _bridge.snapshot().toDart;
    final result = jsAny as _SnapshotResult;
    if (!result.ok.toDart) {
      throw StateError(result.error?.toDart ?? 'Snapshot failed');
    }
    return result.snapshotBuffer!.toDart.asUint8List();
  }

  @override
  Future<void> restore(Uint8List data) async {
    final dataBase64 = base64Encode(data);
    final resultJson = await _bridge.restore(dataBase64.toJS).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(map['error'] as String? ?? 'Restore failed');
    }
  }

  @override
  Future<WasmDiscoverResult> discover() async {
    final jsonStr = _bridge.discover().toDart;
    final map = json.decode(jsonStr) as Map<String, dynamic>;

    return WasmDiscoverResult(
      loaded: map['loaded'] as bool,
      architecture: map['architecture'] as String,
    );
  }

  @override
  Future<void> cancel() async {
    await _bridge.cancel().toDart;
    // Always succeeds (idempotent). No error parsing needed.
  }

  @override
  Future<void> dispose() async {
    await _bridge.dispose().toDart;
    // Always succeeds — Worker terminated.
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  WasmProgressResult _decodeProgress(String jsonStr) {
    final map = json.decode(jsonStr) as Map<String, dynamic>;
    final args = map['args'] as List<Object?>?;
    final rawKwargs = map['kwargs'] as Map<String, dynamic>?;
    final rawTraceback = map['traceback'] as List<Object?>?;
    final rawCallIds = map['pendingCallIds'] as List<Object?>?;

    return WasmProgressResult(
      ok: map['ok'] as bool,
      state: map['state'] as String?,
      value: map['value'],
      printOutput: map['print_output'] as String?,
      functionName: map['functionName'] as String?,
      arguments: args != null ? List<Object?>.from(args) : null,
      kwargs: rawKwargs != null ? Map<String, Object?>.from(rawKwargs) : null,
      callId: map['callId'] as int?,
      methodCall: map['methodCall'] as bool?,
      pendingCallIds: rawCallIds != null ? List<int>.from(rawCallIds) : null,
      error: map['error'] as String?,
      errorType: map['errorType'] as String?,
      excType: map['excType'] as String?,
      traceback: rawTraceback,
    );
  }
}
