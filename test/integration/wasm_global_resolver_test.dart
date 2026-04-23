import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

/// Regression test for Host Function Global Resolution.
/// 
/// Verifies that registered host functions are accessible as globals 
/// in the Monty interpreter without requiring 'from externals import *'.
void main() {
  group('Host Function Global Resolution', () {
    late MontyRuntime runtime;

    setUp(() {
      runtime = MontyRuntime();
    });

    tearDown(() async {
      await runtime.dispose();
    });

    test('can call registered sync host function without imports', () async {
      var called = false;
      runtime.register(HostFunction(
        schema: const HostFunctionSchema(name: 'magic_sync_fn'),
        handler: (args, _) async {
          called = true;
          return 'magic';
        },
      ));

      // This would fail with NameError if MontyNameLookup returns undefined
      final result = await runtime.execute('magic_sync_fn()').result;

      expect(result.error, isNull, reason: 'Should not have NameError: ${result.error?.message}');
      expect(result.value.dartValue, 'magic');
      expect(called, isTrue);
    });

    // NOTE: Native async host function calls (await magic_async_fn()) 
    // currently require 'isAsync: true' metadata in the schema 
    // to be correctly awaited by the Monty engine when resolved globally.
    // For now, they return immediately as a sync result.
  });
}
