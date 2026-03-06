import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/output_formatter.dart';
import 'package:monty_cli/src/verbose_logger.dart';

/// Executes one or more Python expressions in a single session.
///
/// Used by the `-p` / `--prompt` global shortcut. Expressions run
/// sequentially with state persisting between them.
///
/// ```bash
/// monty-cli -p "x = 42" -p "y = x * 2" -p "x + y"
/// # prints: 126
/// ```
Future<int> runPrompts({
  required List<String> prompts,
  required bool json,
  required bool verbose,
  String? libraryPath,
}) async {
  final logger = VerboseLogger(enabled: verbose)
    ..logInit(libraryPath: libraryPath);

  final monty = MontyNative(
    bindings: NativeIsolateBindingsImpl(libraryPath: libraryPath),
  );
  await monty.initialize();
  final session = MontySession(platform: monty);

  try {
    MontyResult? lastResult;

    for (final code in prompts) {
      logger
        ..logRun(code)
        ..logStateRestore(session.state.length);

      try {
        lastResult = await session.run(code);

        logger
          ..logStatePersist(session.state.keys)
          ..logResult(
            memoryBytes: lastResult.usage.memoryBytesUsed,
            timeMs: lastResult.usage.timeElapsedMs,
            stackDepth: lastResult.usage.stackDepthUsed,
            isError: lastResult.isError,
          );
      } on MontyException catch (e) {
        stderr.writeln('Error: ${e.message}');

        return 1;
      }
    }

    if (lastResult != null) {
      if (json) {
        stdout.writeln(OutputFormatter.formatJson(lastResult));
      } else {
        final output = OutputFormatter.format(lastResult);
        if (output.isNotEmpty) stdout.writeln(output);
      }

      return lastResult.isError ? 1 : 0;
    }

    return 0;
  } finally {
    logger.logDispose();
    session.dispose();
    await monty.dispose();
  }
}
