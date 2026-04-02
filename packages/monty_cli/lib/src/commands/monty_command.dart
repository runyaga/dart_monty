import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
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

  /// Creates and initializes a [MontyNative].
  ///
  /// The native library is resolved automatically via @Native annotations.
  /// If the native library cannot be loaded, prints a helpful error message
  /// and exits with code 1.
  Future<MontyNative> createMonty({VerboseLogger? logger}) async {
    logger?.logInit();

    final monty = MontyNative(
      bindings: NativeIsolateBindingsImpl(),
    );
    await monty.initialize();

    return monty;
  }

  /// Returns `true` if [e] is a native library loading failure.
  static bool isLibraryLoadError(MontyException e) {
    return e.message.contains('Failed to load dynamic library') ||
        e.message.contains('Isolate exited unexpectedly');
  }

  /// Prints a user-friendly message for missing native library and exits.
  static Never exitWithLibraryError() {
    stderr.writeln(
      'Error: Could not load native library.\n\n'
      'Make sure libdart_monty_native.dylib is either:\n'
      '  1. Next to the dmonty executable\n'
      '  2. Set via MONTY_LIBRARY_PATH environment variable\n'
      '  3. Passed with --library-path <path>',
    );
    exit(1);
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
