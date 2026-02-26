import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_ffi/src/ffi_core_bindings.dart';
import 'package:dart_monty_ffi/src/native_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Native FFI implementation of [MontyPlatform].
///
/// Extends [BaseMontyPlatform] to inherit run/start/resume/dispose logic
/// and adds [MontySnapshotCapable] and [MontyFutureCapable] capabilities
/// by delegating to [FfiCoreBindings].
///
/// ```dart
/// final monty = MontyFfi(bindings: NativeBindingsFfi());
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyFfi extends BaseMontyPlatform
    implements MontySnapshotCapable, MontyFutureCapable {
  /// Creates a [MontyFfi] with the given [bindings].
  factory MontyFfi({required NativeBindings bindings}) {
    final core = FfiCoreBindings(bindings: bindings);
    return MontyFfi._(coreBindings: core, nativeBindings: bindings);
  }

  MontyFfi._({
    required FfiCoreBindings coreBindings,
    required NativeBindings nativeBindings,
  })  : _nativeBindings = nativeBindings,
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
        ? json.encode(
            errors.map((k, v) => MapEntry(k.toString(), v)),
          )
        : '{}';
    final progress = await coreBindings.resolveFutures(
      resultsJson,
      errorsJson,
    );
    return translateProgress(progress);
  }

  @override
  Future<Uint8List> snapshot() async {
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
