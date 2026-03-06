import 'dart:io';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/commands/monty_command.dart';

/// Executes a Python file and prints the result.
///
/// ```bash
/// dmonty run script.py
/// dmonty run script.py --timeout 5000
/// ```
class RunCommand extends MontyCommand {
  @override
  String get name => 'run';

  @override
  String get description => 'Execute a Python file.';

  @override
  String get invocation => 'dmonty run <file.py>';

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
    final limits = parseLimits(args);
    final logger = createLogger(args);
    final monty = await createMonty(logger: logger);

    logger.logRun(filePath);

    try {
      final result = await monty.run(
        code,
        limits: limits,
        scriptName: filePath,
      );
      writeResult(result, args: args, logger: logger);

      return result.isError ? 1 : 0;
    } on MontyException catch (e) {
      if (MontyCommand.isLibraryLoadError(e)) {
        MontyCommand.exitWithLibraryError();
      }
      stderr.writeln('Error: ${e.message}');

      return 1;
    } finally {
      logger.logDispose();
      await monty.dispose();
    }
  }
}
