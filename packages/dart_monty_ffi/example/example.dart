// ignore_for_file: avoid_print
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Demonstrates direct use of the native FFI bindings.
///
/// Most apps should import `dart_monty` instead — the federated plugin
/// selects the correct backend automatically.
void main() {
  final bindings = NativeBindings();

  // Run a simple expression.
  final json = bindings.run('2 + 2');
  final result = MontyResult.fromJson(json);
  print('Result: ${result.value}'); // 4

  bindings.dispose();
}
