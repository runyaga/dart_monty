// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Demonstrates direct use of the native FFI bindings.
///
/// Most apps should import `dart_monty` instead — the federated plugin
/// selects the correct backend automatically.
void main() {
  // Open the native library (requires libdart_monty_native on the system).
  final bindings = NativeBindingsFfi();

  // Run a simple expression.
  final handle = bindings.create('2 + 2');
  final runResult = bindings.run(handle);
  final resultJson = runResult.resultJson;
  if (resultJson != null) {
    final json = jsonDecode(resultJson) as Map<String, dynamic>;
    final result = MontyResult.fromJson(json);
    print('Result: ${result.value}'); // 4
  }

  bindings.free(handle);
}
