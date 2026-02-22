import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_monty_wasm/src/wasm_bindings.dart';

// ---------------------------------------------------------------------------
// JS interop declarations for window.DartMontyBridge
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _jsInit();

@JS('DartMontyBridge.run')
external JSPromise<JSString> _jsRun(JSString code, [JSString? limitsJson]);

@JS('DartMontyBridge.start')
external JSPromise<JSString> _jsStart(
  JSString code, [
  JSString? extFnsJson,
  JSString? limitsJson,
]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _jsResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _jsResumeWithError(JSString errorJson);

@JS('DartMontyBridge.snapshot')
external JSPromise<JSString> _jsSnapshot();

@JS('DartMontyBridge.restore')
external JSPromise<JSString> _jsRestore(JSString dataBase64);

@JS('DartMontyBridge.discover')
external JSString _jsDiscover();

@JS('DartMontyBridge.dispose')
external JSPromise<JSString> _jsDispose();

/// Concrete [WasmBindings] implementation using `dart:js_interop`.
///
/// Calls into `window.DartMontyBridge` which communicates with a Web Worker
/// hosting the @pydantic/monty WASM runtime.
class WasmBindingsJs extends WasmBindings {
  @override
  Future<bool> init() async {
    final result = await _jsInit().toDart;

    return result.toDart;
  }

  @override
  Future<WasmRunResult> run(String code, {String? limitsJson}) async {
    final resultJson = await _jsRun(
      code.toJS,
      limitsJson?.toJS,
    ).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;

    return WasmRunResult(
      ok: map['ok'] as bool,
      value: map['value'],
      error: map['error'] as String?,
      errorType: map['errorType'] as String?,
    );
  }

  @override
  Future<WasmProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
  }) async {
    final resultJson = await _jsStart(
      code.toJS,
      extFnsJson?.toJS,
      limitsJson?.toJS,
    ).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resume(String valueJson) async {
    final resultJson = await _jsResume(valueJson.toJS).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<WasmProgressResult> resumeWithError(String errorMessage) async {
    final errorJson = json.encode(errorMessage);
    final resultJson = await _jsResumeWithError(errorJson.toJS).toDart;

    return _decodeProgress(resultJson.toDart);
  }

  @override
  Future<Uint8List> snapshot() async {
    final resultJson = await _jsSnapshot().toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(
        map['error'] as String? ?? 'Snapshot failed',
      );
    }
    final dataBase64 = map['data'] as String;

    return base64Decode(dataBase64);
  }

  @override
  Future<void> restore(Uint8List data) async {
    final dataBase64 = base64Encode(data);
    final resultJson = await _jsRestore(dataBase64.toJS).toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(
        map['error'] as String? ?? 'Restore failed',
      );
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
  Future<void> dispose() async {
    final resultJson = await _jsDispose().toDart;
    final map = json.decode(resultJson.toDart) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw StateError(
        map['error'] as String? ?? 'Dispose failed',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  WasmProgressResult _decodeProgress(String jsonStr) {
    final map = json.decode(jsonStr) as Map<String, dynamic>;
    final args = map['args'] as List<Object?>?;

    return WasmProgressResult(
      ok: map['ok'] as bool,
      state: map['state'] as String?,
      value: map['value'],
      functionName: map['functionName'] as String?,
      arguments: args != null ? List<Object?>.from(args) : null,
      error: map['error'] as String?,
      errorType: map['errorType'] as String?,
    );
  }
}
