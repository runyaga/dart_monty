import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/library_resolver.dart';
import 'package:monty_cli/src/output_formatter.dart';

/// Evaluates a single Python expression and prints the result.
///
/// ```bash
/// monty-cli eval "2 + 2"
/// monty-cli eval "sum(range(100))" --json
/// ```
class EvalCommand extends Command<int> {
  /// Creates an [EvalCommand].
  EvalCommand() {
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
  String get name => 'eval';

  @override
  String get description => 'Evaluate a Python expression.';

  @override
  String get invocation => 'monty-cli eval "<expression>"';

  @override
  Future<int> run() async {
    final args = argResults!;
    final rest = args.rest;
    if (rest.isEmpty) {
      usageException('Provide a Python expression to evaluate.');
    }

    final expression = rest.join(' ');
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

      final result = await monty.run(expression, limits: limits);

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
