import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/commands/monty_command.dart';
import 'package:monty_cli/src/verbose_logger.dart';

/// Built-in host function handlers for the demo.
///
/// Each handler receives positional [args] and optional [kwargs],
/// returning the value that Python sees as the function's return value.
typedef HostHandler =
    Object? Function(
      List<Object?> args,
      Map<String, Object?>? kwargs,
    );

/// Demonstrates the external function dispatch loop (start/resume).
///
/// Runs a Python script that calls host functions registered with the
/// interpreter. The CLI fulfills each call with built-in handlers and
/// resumes execution until complete.
///
/// ```bash
/// dmonty demo
/// dmonty demo --script 'greet("world")'
/// dmonty demo --list
/// ```
class DemoCommand extends MontyCommand {
  /// Creates a [DemoCommand] and registers demo-specific flags.
  DemoCommand() {
    argParser
      ..addOption(
        'script',
        abbr: 's',
        help: 'Python code to run (uses built-in demo script if omitted).',
        valueHelp: 'code',
      )
      ..addFlag(
        'list',
        abbr: 'l',
        help: 'List available host functions and exit.',
        negatable: false,
      );
  }

  @override
  String get name => 'demo';

  @override
  String get description =>
      'Run Python code with built-in host function dispatch.';

  /// The built-in host functions available to Python code.
  static final Map<String, HostHandler> hostFunctions = {
    'greet': (args, kwargs) {
      final name = args.isNotEmpty ? args.first : 'world';
      final greeting = kwargs?['greeting'] ?? 'Hello';
      return '$greeting, $name!';
    },
    'add': (args, kwargs) {
      if (args.length < 2 || args[0] is! num || args[1] is! num) {
        return 'Error: add() requires two numbers';
      }
      return (args[0]! as num) + (args[1]! as num);
    },
    'uppercase': (args, kwargs) {
      if (args.isEmpty || args.first is! String) {
        return 'Error: uppercase() requires a string';
      }
      return (args.first! as String).toUpperCase();
    },
    'reverse': (args, kwargs) {
      if (args.isEmpty || args.first is! String) {
        return 'Error: reverse() requires a string';
      }
      final s = args.first! as String;
      return String.fromCharCodes(s.codeUnits.reversed);
    },
    'length': (args, kwargs) {
      final value = args.first;
      if (value is String) return value.length;
      if (value is List) return value.length;
      return 0;
    },
  };

  /// Default demo script that exercises multiple host functions.
  static const _defaultScript = '''
msg = greet("Monty", greeting="Howdy")
result = add(10, 32)
shouted = uppercase(msg)
backwards = reverse("Python")
size = length([1, 2, 3, 4, 5])
(msg, result, shouted, backwards, size)
''';

  @override
  Future<int> run() async {
    final args = argResults!;

    if (args.flag('list')) {
      _printHostFunctions();
      return 0;
    }

    final code = args.option('script') ?? _defaultScript;
    final limits = parseLimits(args);
    final logger = createLogger(args);
    final monty = await createMonty(logger: logger);

    try {
      return await _dispatchLoop(
        monty: monty,
        code: code,
        limits: limits,
        logger: logger,
        args: args,
      );
    } finally {
      logger.logDispose();
      await monty.dispose();
    }
  }

  void _printHostFunctions() {
    stdout.writeln('Available host functions:\n');
    const docs = {
      'greet': 'greet(name, greeting="Hello") -> str',
      'add': 'add(a, b) -> num',
      'uppercase': 'uppercase(s) -> str',
      'reverse': 'reverse(s) -> str',
      'length': 'length(value) -> int',
    };
    for (final entry in docs.entries) {
      stdout.writeln('  ${entry.value}');
    }
  }

  Future<int> _dispatchLoop({
    required MontyPlatform monty,
    required String code,
    required VerboseLogger logger,
    required ArgResults args,
    MontyLimits? limits,
  }) async {
    logger.logRun(code);

    var progress = await monty.start(
      code,
      externalFunctions: hostFunctions.keys.toList(),
      limits: limits,
    );

    while (progress is MontyPending) {
      final fn = progress.functionName;
      final fnArgs = progress.arguments;
      final kwargs = progress.kwargs;

      logger.log(
        'host call: $fn(${fnArgs.join(", ")}'
        '${kwargs != null && kwargs.isNotEmpty ? ", $kwargs" : ""})',
      );

      final handler = hostFunctions[fn];
      if (handler == null) {
        stderr.writeln('Unknown host function: $fn');
        progress = await monty.resumeWithError(
          'No handler registered for "$fn"',
        );

        continue;
      }

      final returnValue = handler(fnArgs, kwargs);
      logger.log('host return: $returnValue');
      progress = await monty.resume(returnValue);
    }

    if (progress is MontyComplete) {
      final result = progress.result;

      logger.logResult(
        memoryBytes: result.usage.memoryBytesUsed,
        timeMs: result.usage.timeElapsedMs,
        stackDepth: result.usage.stackDepthUsed,
        isError: result.isError,
      );

      writeResult(result, args: args, logger: logger);

      return result.isError ? 1 : 0;
    }

    stderr.writeln('Unexpected progress state: $progress');
    return 1;
  }
}
