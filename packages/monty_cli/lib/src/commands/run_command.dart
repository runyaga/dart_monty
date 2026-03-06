import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/library_resolver.dart';
import 'package:monty_cli/src/output_formatter.dart';

/// Executes a Python file and prints the result.
///
/// ```bash
/// monty-cli run script.py
/// monty-cli run script.py --timeout 5000
/// ```
class RunCommand extends Command<int> {
  /// Creates a [RunCommand].
  RunCommand() {
    argParser
      ..addFlag('json', help: 'Output result as JSON.', negatable: false)
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Show resource usage stats.',
        negatable: false,
      )
      ..addOption(
        'timeout',
        help: 'Execution timeout in milliseconds.',
        valueHelp: 'ms',
      )
      ..addOption(
        'memory',
        help: 'Memory limit in bytes.',
        valueHelp: 'bytes',
      )
      ..addOption(
        'stack-depth',
        help: 'Maximum stack depth.',
        valueHelp: 'depth',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Execute a Python file.';

  @override
  String get invocation => 'monty-cli run <file.py>';

  @override
  Future<int> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      usageException('Provide a Python file to run.');
    }

    final filePath = rest.first;
    final file = File(filePath);
    if (!file.existsSync()) {
      stderr.writeln('Error: file not found: $filePath');

      return 1;
    }

    final code = file.readAsStringSync();
    final useJson = args.flag('json');
    final verbose = args.flag('verbose');
    final limits = _parseLimits(args);

    final libraryPath = resolveLibraryPath(
      override: globalResults?.option('library-path'),
    );

    final monty = MontyNative(
      bindings: NativeIsolateBindingsImpl(libraryPath: libraryPath),
    );

    try {
      await monty.initialize();

      final result = await monty.run(
        code,
        limits: limits,
        scriptName: filePath,
      );

      if (useJson) {
        stdout.writeln(OutputFormatter.formatJson(result));
      } else if (verbose) {
        stdout.writeln(OutputFormatter.formatVerbose(result));
      } else {
        final output = OutputFormatter.format(result);
        if (output.isNotEmpty) stdout.writeln(output);
      }

      return result.isError ? 1 : 0;
    } on MontyException catch (e) {
      stderr.writeln('Error: ${e.message}');

      return 1;
    } finally {
      await monty.dispose();
    }
  }

  MontyLimits? _parseLimits(ArgResults args) {
    final timeout = args.option('timeout');
    final memory = args.option('memory');
    final stackDepth = args.option('stack-depth');

    if (timeout == null && memory == null && stackDepth == null) return null;

    return MontyLimits(
      timeoutMs: timeout != null ? int.parse(timeout) : null,
      memoryBytes: memory != null ? int.parse(memory) : null,
      stackDepth: stackDepth != null ? int.parse(stackDepth) : null,
    );
  }
}
