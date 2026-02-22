// ignore_for_file: avoid_print
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';

/// Demonstrates direct use of the WASM bindings.
///
/// Most apps should import `dart_monty` instead — the federated plugin
/// selects the correct backend automatically. This package is intended
/// for browser environments only.
Future<void> main() async {
  final monty = MontyWasm(bindings: WasmBindingsJs());

  final result = await monty.run('2 + 2');
  print('Result: ${result.value}'); // 4

  await monty.dispose();
}
