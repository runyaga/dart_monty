import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/library_resolver.dart';
import 'package:monty_cli/src/output_formatter.dart';
import 'package:monty_cli/src/verbose_logger.dart';

/// Base class for monty CLI commands that execute Python code.
///
/// Provides shared flags (`--json`, `--verbose`, `--timeout`, `--memory`,
/// `--stack-depth`), Monty lifecycle management, and output formatting.
abstract class MontyCommand extends Command<int> {
  /// Creates a [MontyCommand] and registers shared flags.
  MontyCommand() {
    argParser
      ..addFlag('json', help: 'Output result as JSON.', negatable: false)
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Show detailed lifecycle events on stderr.',
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

  /// Parses resource limit flags into a [MontyLimits], or `null` if none set.
  MontyLimits? parseLimits(ArgResults args) {
    final timeout = args.option('timeout');
    final memory = args.option('memory');
    final stackDepth = args.option('stack-depth');

    if (timeout == null && memory == null && stackDepth == null) return null;

    try {
      return MontyLimits(
        timeoutMs: timeout != null ? int.parse(timeout) : null,
        memoryBytes: memory != null ? int.parse(memory) : null,
        stackDepth: stackDepth != null ? int.parse(stackDepth) : null,
      );
    } on FormatException catch (e) {
      usageException('Invalid integer for resource limit: ${e.message}');
    }
  }

  /// Creates a [VerboseLogger] based on the `--verbose` flag.
  VerboseLogger createLogger(ArgResults args) {
    return VerboseLogger(enabled: args.flag('verbose'));
  }

  /// Creates and initializes a [MontyNative] with the resolved library path.
  Future<MontyNative> createMonty({VerboseLogger? logger}) async {
    final libraryPath = resolveLibraryPath(
      override: globalResults?.option('library-path'),
    );
    logger?.logInit(libraryPath: libraryPath);

    final monty = MontyNative(
      bindings: NativeIsolateBindingsImpl(libraryPath: libraryPath),
    );
    await monty.initialize();

    return monty;
  }

  /// Writes [result] to stdout/stderr based on the output mode flags.
  void writeResult(
    MontyResult result, {
    required ArgResults args,
    VerboseLogger? logger,
  }) {
    final useJson = args.flag('json');

    if (useJson) {
      stdout.writeln(OutputFormatter.formatJson(result));
    } else {
      final output = OutputFormatter.format(result);
      if (output.isNotEmpty) stdout.writeln(output);
    }

    logger?.logResult(
      memoryBytes: result.usage.memoryBytesUsed,
      timeMs: result.usage.timeElapsedMs,
      stackDepth: result.usage.stackDepthUsed,
      isError: result.isError,
    );
  }
}
