import 'package:monty_cli/src/cli_runner.dart';
import 'package:test/test.dart';

void main() {
  group('eval command', () {
    test('runner contains eval command', () {
      final runner = buildRunner();
      expect(runner.commands.keys, contains('eval'));
    });

    test('runner contains run command', () {
      final runner = buildRunner();
      expect(runner.commands.keys, contains('run'));
    });

    test('runner contains repl command', () {
      final runner = buildRunner();
      expect(runner.commands.keys, contains('repl'));
    });

    test('runner has --prompt global option', () {
      final runner = buildRunner();
      expect(runner.argParser.options.keys, contains('prompt'));
    });

    test('--prompt accepts multiple values', () {
      final runner = buildRunner();
      final result = runner.argParser.parse(
        ['-p', 'x=1', '-p', 'x+1'],
      );
      expect(result.multiOption('prompt'), ['x=1', 'x+1']);
    });

    test('runner --help does not throw', () async {
      final runner = buildRunner();
      final result = await runner.run(['--help']);
      expect(result, isNull);
    });
  });
}
