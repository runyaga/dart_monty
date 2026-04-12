import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_monty/src/wasm/wasm_bindings.dart';

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
// JS interop for window.DartMontyBridge
// ---------------------------------------------------------------------------
//
// The JS bridge exposes `window.DartMontyBridge` as a plain object with
// static methods. Each method accepts an optional sessionId as the last
// parameter for multi-session routing.

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _jsInit();

@JS('DartMontyBridge.createSession')
external JSPromise<JSNumber> _jsCreateSession();

@JS('DartMontyBridge.run')
external JSPromise<JSString> _jsRun(
  JSString code, [
  JSString? limitsJson,
  JSString? scriptName,
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.start')
external JSPromise<JSString> _jsStart(
  JSString code, [
  JSString? extFnsJson,
  JSString? limitsJson,
  JSString? scriptName,
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _jsResume(
  JSString valueJson, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _jsResumeWithError(
  JSString errorJson, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.resumeAsFuture')
external JSPromise<JSString> _jsResumeAsFuture([JSNumber? sessionId]);

@JS('DartMontyBridge.resolveFutures')
external JSPromise<JSString> _jsResolveFutures(
  JSString resultsJson,
  JSString errorsJson, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.snapshot')
external JSPromise<JSAny> _jsSnapshot([JSNumber? sessionId]);

@JS('DartMontyBridge.restore')
external JSPromise<JSString> _jsRestore(
  JSString dataBase64, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.discover')
external JSString _jsDiscover();

@JS('DartMontyBridge.dispose')
external JSPromise<JSString> _jsDispose([JSNumber? sessionId]);

@JS('DartMontyBridge.disposeSession')
external void _jsDisposeSession(JSNumber sessionId);

@JS('DartMontyBridge.replCreate')
external JSPromise<JSString> _jsReplCreate([
  JSString? scriptName,
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.replFree')
external JSPromise<JSString> _jsReplFree([JSNumber? sessionId]);

@JS('DartMontyBridge.replFeedRun')
external JSPromise<JSString> _jsReplFeedRun(
  JSString code, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.replDetectContinuation')
external JSPromise<JSString> _jsReplDetectContinuation(
  JSString source, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.replSetExtFns')
external JSPromise<JSString> _jsReplSetExtFns(
  JSString extFns, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.replFeedStart')
external JSPromise<JSString> _jsReplFeedStart(
  JSString code, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.replResume')
external JSPromise<JSString> _jsReplResume(
  JSString valueJson, [
  JSNumber? sessionId,
]);

@JS('DartMontyBridge.replResumeWithError')
external JSPromise<JSString> _jsReplResumeWithError(
  JSString errorJson, [
  JSNumber? sessionId,
]);

/// Concrete [WasmBindings] implementation using `dart:js_interop`.
///
/// Calls static methods on `window.DartMontyBridge`, which manages a
/// Worker session pool internally. Each session gets its own Worker.
class WasmBindingsJs extends WasmBindings {
  /// Creates a [WasmBindingsJs].
  WasmBindingsJs();

  bool _initialized = false;

  @override
  Future<bool> init() async {
    await _ensureInit();

    return true;
  }

  @override
  Future<int> createSession() async {
    await _ensureInit();
    final jsSessionId = await _jsCreateSession().toDart;

    return jsSessionId.toDartInt;
  }

  @override
  Future<void> disposeSession(int sessionId) async {
    _jsDisposeSession(sessionId.toJS);
  }

  @override
  Future<WasmRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
    int? sessionId,
  }) async {
    final resultJson = await _jsRun(
      code.toJS,
      limitsJson?.toJS,
      scriptName?.toJS,
      sessionId?.toJS,
    ).toDart;
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
      filename: map['filename'] as String?,
      lineNumber: map['line_number'] as int?,
      columnNumber: map['column_number'] as int?,
      sourceCode: map['source_code'] as String?,
    );
  }

  @override
  Future<WasmProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
    int? sessionId,
  }) async {
    final resultJson = await _jsStart(
      code.toJS,
      extFnsJson?.toJS,
      limitsJson?.toJS,
      scriptName?.toJS,
      sessionId?.toJS,
    ).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resume(
    String valueJson, {
    int? sessionId,
  }) async {
    final resultJson = await _jsResume(valueJson.toJS, sessionId?.toJS).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resumeWithError(
    String errorMessage, {
    int? sessionId,
  }) async {
    final errorJson = json.encode(errorMessage);
    final resultJson = await _jsResumeWithError(
      errorJson.toJS,
      sessionId?.toJS,
    ).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resumeAsFuture({int? sessionId}) async {
    final resultJson = await _jsResumeAsFuture(sessionId?.toJS).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson, {
    int? sessionId,
  }) async {
    final resultJson = await _jsResolveFutures(
      resultsJson.toJS,
      errorsJson.toJS,
      sessionId?.toJS,
    ).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<Uint8List> snapshot({int? sessionId}) async {
    final jsAny = await _jsSnapshot(sessionId?.toJS).toDart;
    final result = jsAny as _SnapshotResult;
    if (!result.ok.toDart) {
      throw StateError(result.error?.toDart ?? 'Snapshot failed');
    }

    return result.snapshotBuffer!.toDart.asUint8List();
  }

  @override
  Future<void> restore(Uint8List data, {int? sessionId}) async {
    final dataBase64 = base64Encode(data);
    final resultJson = await _jsRestore(
      dataBase64.toJS,
      sessionId?.toJS,
    ).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(map['error'] as String? ?? 'Restore failed');
    }
  }

  @override
  Future<WasmDiscoverResult> discover() async {
    final jsonStr = _jsDiscover().toDart;
    final map = json.decode(jsonStr) as Map<String, dynamic>;

    return WasmDiscoverResult(
      loaded: map['loaded'] as bool,
      architecture: map['architecture'] as String,
    );
  }

  @override
  Future<void> dispose({int? sessionId}) async {
    await _jsDispose(sessionId?.toJS).toDart;
  }

  // ---------------------------------------------------------------------------
  // REPL
  // ---------------------------------------------------------------------------

  @override
  Future<void> replCreate({String? scriptName, int? sessionId}) async {
    await _ensureInit();
    final resultJson = await _jsReplCreate(
      scriptName?.toJS,
      sessionId?.toJS,
    ).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(
        map['error'] as String? ?? 'replCreate failed',
      );
    }
  }

  @override
  Future<void> replFree({int? sessionId}) async {
    final resultJson = await _jsReplFree(sessionId?.toJS).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(
        map['error'] as String? ?? 'replFree failed',
      );
    }
  }

  @override
  Future<WasmRunResult> replFeedRun(String code, {int? sessionId}) async {
    final resultJson = await _jsReplFeedRun(code.toJS, sessionId?.toJS).toDart;
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
      filename: map['filename'] as String?,
      lineNumber: map['line_number'] as int?,
      columnNumber: map['column_number'] as int?,
      sourceCode: map['source_code'] as String?,
    );
  }

  @override
  Future<int> replDetectContinuation(
    String source, {
    int? sessionId,
  }) async {
    final resultJson = await _jsReplDetectContinuation(
      source.toJS,
      sessionId?.toJS,
    ).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(
        map['error'] as String? ?? 'replDetectContinuation failed',
      );
    }

    return map['value'] as int;
  }

  // ---------------------------------------------------------------------------
  // REPL iterative execution
  // ---------------------------------------------------------------------------

  @override
  Future<void> replSetExtFns(String extFns, {int? sessionId}) async {
    final resultJson = await _jsReplSetExtFns(
      extFns.toJS,
      sessionId?.toJS,
    ).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(
        map['error'] as String? ?? 'replSetExtFns failed',
      );
    }
  }

  @override
  Future<WasmProgressResult> replFeedStart(
    String code, {
    int? sessionId,
  }) async {
    final resultJson = await _jsReplFeedStart(
      code.toJS,
      sessionId?.toJS,
    ).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> replResume(
    String valueJson, {
    int? sessionId,
  }) async {
    final resultJson = await _jsReplResume(
      valueJson.toJS,
      sessionId?.toJS,
    ).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> replResumeWithError(
    String errorJson, {
    int? sessionId,
  }) async {
    final resultJson = await _jsReplResumeWithError(
      errorJson.toJS,
      sessionId?.toJS,
    ).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Ensures the default JS bridge session is initialized.
  ///
  /// The static `DartMontyBridge.init()` creates a default Worker session.
  /// Subsequent `createSession()` calls create additional sessions with
  /// their own Workers.
  Future<void> _ensureInit() async {
    if (_initialized) return;
    await _jsInit().toDart;
    _initialized = true;
  }

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
      kwargs: rawKwargs != null ? Map.from(rawKwargs) : null,
      callId: map['callId'] as int?,
      methodCall: map['methodCall'] as bool?,
      pendingCallIds: rawCallIds != null ? List<int>.from(rawCallIds) : null,
      error: map['error'] as String?,
      errorType: map['errorType'] as String?,
      excType: map['excType'] as String?,
      traceback: rawTraceback,
      filename: map['filename'] as String?,
      lineNumber: map['line_number'] as int?,
      columnNumber: map['column_number'] as int?,
      sourceCode: map['source_code'] as String?,
    );
  }
}
