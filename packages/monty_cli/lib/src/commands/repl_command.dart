import 'dart:io';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/commands/monty_command.dart';
import 'package:monty_cli/src/output_formatter.dart';
import 'package:monty_cli/src/verbose_logger.dart';

/// Interactive multi-turn REPL with persistent Python state.
///
/// Variables defined in one line carry over to subsequent lines via
/// [MontySession]. Supports slash-commands for session management.
///
/// ```bash
/// dmonty repl
/// monty> x = 42
/// monty> x * 2
/// 84
/// monty> /state
/// {x: 42}
/// monty> /quit
/// ```
class ReplCommand extends MontyCommand {
  @override
  String get name => 'repl';

  @override
  String get description => 'Interactive Python REPL with persistent state.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final limits = parseLimits(args);
    final logger = createLogger(args);
    final monty = await createMonty(logger: logger);
    final session = MontySession(platform: monty);

    stdout.writeln('monty REPL (Ctrl-D to exit, /help for commands)');

    try {
      await _readLoop(
        session: session,
        limits: limits,
        logger: logger,
      );

      return 0;
    } finally {
      logger.logDispose();
      session.dispose();
      await monty.dispose();
    }
  }

  Future<void> _readLoop({
    required MontySession session,
    required VerboseLogger logger,
    MontyLimits? limits,
  }) async {
    while (true) {
      stdout.write('monty> ');
      final line = stdin.readLineSync();

      // Ctrl-D (EOF)
      if (line == null) {
        stdout.writeln();

        return;
      }

      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Slash-commands
      if (trimmed.startsWith('/')) {
        final shouldContinue = _handleSlashCommand(trimmed, session);
        if (!shouldContinue) return;
        continue;
      }

      // Execute Python
      await _execute(
        session: session,
        code: trimmed,
        limits: limits,
        logger: logger,
      );
    }
  }

  /// Handles a slash-command. Returns `false` if the REPL should exit.
  bool _handleSlashCommand(String command, MontySession session) {
    switch (command) {
      case '/quit' || '/exit' || '/q':
        return false;

      case '/help' || '/h':
        stdout.writeln(
          '/help     Show this help\n'
          '/state    Show persisted variables\n'
          '/clear    Clear persisted state\n'
          '/quit     Exit the REPL',
        );

      case '/state' || '/s':
        final state = session.state;
        if (state.isEmpty) {
          stdout.writeln('(no state)');
        } else {
          for (final entry in state.entries) {
            stdout.writeln('  ${entry.key} = ${entry.value}');
          }
        }

      case '/clear':
        session.clearState();
        stdout.writeln('State cleared.');

      default:
        stderr.writeln('Unknown command: $command (try /help)');
    }

    return true;
  }

  Future<void> _execute({
    required MontySession session,
    required String code,
    required VerboseLogger logger,
    MontyLimits? limits,
  }) async {
    logger
      ..logRun(code)
      ..logStateRestore(session.state.length);

    try {
      final result = await session.run(code, limits: limits);

      logger
        ..logStatePersist(session.state.keys)
        ..logResult(
          memoryBytes: result.usage.memoryBytesUsed,
          timeMs: result.usage.timeElapsedMs,
          stackDepth: result.usage.stackDepthUsed,
          isError: result.isError,
        );

      final output = OutputFormatter.format(result);
      if (output.isNotEmpty) stdout.writeln(output);
    } on MontyException catch (e) {
      if (MontyCommand.isLibraryLoadError(e)) {
        MontyCommand.exitWithLibraryError();
      }
      stderr.writeln('Error: ${e.message}');
    } on Exception catch (e) {
      stderr.writeln('Error: $e');
    }
  }
}
