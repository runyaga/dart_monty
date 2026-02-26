import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/src/wasm_bindings.dart';
import 'package:dart_monty_wasm/src/wasm_core_bindings.dart';

/// Web WASM implementation of [MontyPlatform].
///
/// Extends [BaseMontyPlatform] to inherit run/start/resume/dispose logic
/// and adds [MontySnapshotCapable] for snapshot/restore support.
///
/// ```dart
/// final monty = MontyWasm(bindings: WasmBindingsJs());
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyWasm extends BaseMontyPlatform implements MontySnapshotCapable {
  /// Creates a [MontyWasm] with the given [bindings].
  factory MontyWasm({required WasmBindings bindings}) {
    final core = WasmCoreBindings(bindings: bindings);
    return MontyWasm._(coreBindings: core, wasmBindings: bindings);
  }

  MontyWasm._({
    required WasmCoreBindings coreBindings,
    required WasmBindings wasmBindings,
  })  : _wasmBindings = wasmBindings,
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
}
