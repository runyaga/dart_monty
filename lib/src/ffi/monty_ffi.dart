import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty/src/ffi/ffi_core_bindings.dart';
import 'package:dart_monty/src/ffi/native_bindings.dart';
import 'package:dart_monty/src/ffi/native_bindings_ffi.dart';
import 'package:dart_monty/src/platform/base_monty_platform.dart';
import 'package:dart_monty/src/platform/monty_future_capable.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_snapshot_capable.dart';

/// Native FFI implementation of [MontyPlatform].
///
/// Extends [BaseMontyPlatform] to inherit run/start/resume/dispose logic
/// and adds [MontySnapshotCapable] and [MontyFutureCapable] capabilities
/// by delegating to [FfiCoreBindings].
///
/// ```dart
/// final monty = MontyFfi();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyFfi extends BaseMontyPlatform
    implements MontySnapshotCapable, MontyFutureCapable {
  /// Creates a [MontyFfi] with optional [bindings].
  ///
  /// Defaults to [NativeBindingsFfi] when omitted.
  factory MontyFfi({NativeBindings? bindings}) {
    final b = bindings ?? NativeBindingsFfi(); // coverage:ignore-line
    final core = FfiCoreBindings(bindings: b);

    return MontyFfi._(coreBindings: core, nativeBindings: b);
  }

  /// Creates a [MontyFfi] with pre-built [FfiCoreBindings].
  ///
  /// Used by the isolate worker to inject pre-configured core bindings.
  MontyFfi.withCore({
    required FfiCoreBindings coreBindings,
    required NativeBindings nativeBindings,
  }) : _nativeBindings = nativeBindings,
       super(bindings: coreBindings);

  MontyFfi._({
    required FfiCoreBindings coreBindings,
    required NativeBindings nativeBindings,
  }) : _nativeBindings = nativeBindings,
       super(bindings: coreBindings);

  final NativeBindings _nativeBindings;

  @override
  String get backendName => 'MontyFfi';

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
    final core = FfiCoreBindings(bindings: _nativeBindings);
    await core.restoreSnapshot(data);

    return MontyFfi._(coreBindings: core, nativeBindings: _nativeBindings)
      ..markActive();
  }
}
