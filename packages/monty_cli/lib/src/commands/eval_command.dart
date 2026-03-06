import 'dart:io';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/commands/monty_command.dart';

/// Evaluates a single Python expression and prints the result.
///
/// ```bash
/// monty-cli eval "2 + 2"
/// monty-cli eval "sum(range(100))" --json
/// ```
class EvalCommand extends MontyCommand {
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
    final limits = parseLimits(args);
    final logger = createLogger(args);
    final monty = await createMonty(logger: logger);

    logger.logRun(expression);

    try {
      final result = await monty.run(expression, limits: limits);
      writeResult(result, args: args, logger: logger);

      return result.isError ? 1 : 0;
    } on MontyException catch (e) {
      stderr.writeln('Error: ${e.message}');

      return 1;
    } finally {
      logger.logDispose();
      await monty.dispose();
    }
  }
}
