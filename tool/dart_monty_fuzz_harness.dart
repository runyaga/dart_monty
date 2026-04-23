import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:args/args.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('target', abbr: 't', allowed: ['ffi', 'wasm'], defaultsTo: 'ffi')
    ..addOption('file', abbr: 'f', help: 'Path to the Monty script to run');

  final results = parser.parse(arguments);
  final target = results['target'] as String;
  final filePath = results['file'] as String?;

  if (filePath == null) {
    print('Usage: dart_monty_harness --file <path> [--target <ffi|wasm>]');
    exit(1);
  }

  final file = File(filePath);
  if (!file.existsSync()) {
    print('Error: File not found: $filePath');
    exit(1);
  }

  final content = file.readAsStringSync();

  if (target == 'wasm') {
    print('Error: WASM target not supported in CLI harness yet.');
    exit(1);
  }

  final runtime = MontyRuntime();
  
  // Register higher-level HostFunctions
  runtime.register(HostFunction(
    schema: const HostFunctionSchema(name: 'host_sync_get_counter'),
    handler: (args, _) async => 0, // Placeholder
  ));
  
  runtime.register(HostFunction(
    schema: const HostFunctionSchema(name: 'host_async_delay'),
    handler: (args, _) async {
      final ms = args['ms'] as int? ?? 10;
      await Future.delayed(Duration(milliseconds: ms));
      return 'slept_$ms';
    },
  ));

  try {
    if (content.contains('# --- MONTY_SESSION_STEP ---')) {
      final steps = content.split('# --- MONTY_SESSION_STEP ---');
      for (var stepCode in steps) {
        final step = stepCode.trim();
        if (step.isEmpty) continue;
        final res = await runtime.execute(step).result;
        if (res.error != null) {
           print('Monty Error: ${res.error!.message}');
           exit(2);
        }
      }
    } else {
      final res = await runtime.execute(content).result;
      if (res.error != null) {
        print('Monty Error: ${res.error!.message}');
        exit(2);
      } else {
        print('Success: ${res.value}');
      }
    }
    exit(0);
  } catch (e, stack) {
    stderr.writeln('Unexpected Runtime Error: $e');
    stderr.writeln(stack);
    exit(1);
  } finally {
    await runtime.dispose();
  }
}
