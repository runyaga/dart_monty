import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/monty_backend_spi.dart';
import 'package:dart_monty_wasm/src/wasm_bindings.dart';
import 'package:dart_monty_wasm/src/wasm_bindings_js_stub.dart'
    if (dart.library.js_interop) 'package:dart_monty_wasm/src/wasm_bindings_js.dart';
import 'package:dart_monty_wasm/src/wasm_core_bindings.dart';

/// Web WASM implementation of [MontyPlatform].
///
/// Extends [BaseMontyPlatform] to inherit run/start/resume/dispose logic
/// and adds [MontySnapshotCapable] for snapshot/restore and
/// [MontyFutureCapable] for async Python future resolution.
///
/// ```dart
/// final monty = MontyWasm();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyWasm extends BaseMontyPlatform
    implements MontySnapshotCapable, MontyFutureCapable {
  /// Creates a [MontyWasm] with optional [bindings].
  ///
  /// Defaults to [WasmBindingsJs] when omitted.
  factory MontyWasm({WasmBindings? bindings}) {
    final b = bindings ?? WasmBindingsJs();
    final core = WasmCoreBindings(bindings: b);

    return MontyWasm._(coreBindings: core, wasmBindings: b);
  }

  MontyWasm._({
    required WasmCoreBindings coreBindings,
    required WasmBindings wasmBindings,
  }) : _wasmBindings = wasmBindings,
       super(bindings: coreBindings);

  final WasmBindings _wasmBindings;

  @override
  String get backendName => 'MontyWasm';

  @override
  Future<Uint8List> snapshot() {
    assertNotDisposed('snapshot');
    assertActive('snapshot');

    return coreBindings.snapshot();
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    assertNotDisposed('restore');
    assertIdle('restore');
    final core = WasmCoreBindings(bindings: _wasmBindings);
    await core.restoreSnapshot(data);

    return MontyWasm._(coreBindings: core, wasmBindings: _wasmBindings)
      ..markActive();
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    assertNotDisposed('resumeAsFuture');
    assertActive('resumeAsFuture');
    final progress = await coreBindings.resumeAsFuture();

    return translateProgress(progress);
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
    assertNotDisposed('resolveFutures');
    assertActive('resolveFutures');
    final resultsJson = json.encode(
      results.map((k, v) => MapEntry(k.toString(), v)),
    );
    final errorsJson = errors != null
        ? json.encode(errors.map((k, v) => MapEntry(k.toString(), v)))
        : '{}';
    final progress = await coreBindings.resolveFutures(resultsJson, errorsJson);

    return translateProgress(progress);
  }
}
