// Compilers validate actual imports independently of the source inventory.
@TestOn('vm')
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _compile(File source, Directory temp, String compiler) =>
    Process.run(
      Platform.resolvedExecutable,
      [
        '--suppress-analytics',
        'compile',
        compiler,
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        source.path,
        '-o',
        '${temp.path}/output.${compiler == "kernel" ? "dill" : compiler}',
      ],
      environment: {'CI': 'true'},
    );

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('dm-surface-'));
  tearDown(() => temp.deleteSync(recursive: true));

  for (final compiler in ['kernel', 'js', 'wasm']) {
    test('all facade names compile with $compiler', () async {
      final names =
          (jsonDecode(
                    File('test/surface/names.json').readAsStringSync(),
                  )
                  as List<dynamic>)
              .cast<String>()
              .toSet()
            ..remove('DecoratorHandlers');
      if (compiler != 'kernel') names.remove('sandboxedFsHandler');
      final source = File('${temp.path}/positive.dart')
        ..writeAsStringSync('''
import 'package:dart_monty/dart_monty.dart' as dm;
import 'package:dart_monty_core/dart_monty_core.dart' show MontyInt;
void main() {
  final dm.MontyValue none = const dm.MontyNone();
  final dm.MontyValue value = const MontyInt(42);
  print([none.dartValue, value, ${names.map((n) => 'dm.$n').join(', ')}]);
}
dm.OsHandler decorate(dm.OsHandler handler) =>
    dm.DecoratorHandlers(handler).readOnly();
''');
      final result = await _compile(source, temp, compiler);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });
  }

  group('every D2 deleted name, member and library', () {
    setUpAll(() async {
      final controlDir = Directory.systemTemp.createTempSync('dm-control-');
      try {
        final control = File('${controlDir.path}/control.dart')
          ..writeAsStringSync('''
import 'package:dart_monty/dart_monty.dart';
void main() { final MontyValue value = const MontyNone(); print(value); }
''');
        final positive = await _compile(control, controlDir, 'kernel');
        expect(
          positive.exitCode,
          0,
          reason: '${positive.stdout}${positive.stderr}',
        );
      } finally {
        controlDir.deleteSync(recursive: true);
      }
    });

    final cases =
        jsonDecode(
              File('test/surface/negative_cases.json').readAsStringSync(),
            )
            as List<dynamic>;
    for (final entry in cases.cast<Map<String, dynamic>>()) {
      test('rejects ${entry['id']}', () async {
        final source = File('${temp.path}/${entry['id']}.dart')
          ..writeAsStringSync('''
import 'package:dart_monty/dart_monty.dart';
${entry['imports'] ?? ''}
void main() { ${entry['body']} }
''');
        final result = await _compile(source, temp, 'kernel');
        final output = '${result.stdout}${result.stderr}';
        expect(result.exitCode, isNot(0), reason: '${entry['id']} compiled');
        final errors = const LineSplitter()
            .convert(output)
            .where(
              (line) => line.contains('Error:'),
            );
        expect(errors, isNotEmpty, reason: output);
        for (final error in errors) {
          expect(error, startsWith('${source.path}:'), reason: output);
          if (error.contains('Error when reading') ||
              error.contains('Not found:')) {
            expect(entry['missing_library'], isNotNull, reason: output);
            expect(error, contains(entry['missing_library'] as String));
          }
        }
      });
    }
  });
}
