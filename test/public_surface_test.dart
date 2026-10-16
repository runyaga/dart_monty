// Exact D2 surface: typedefs and extension names are declarations too.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty/dart_monty.dart' as dm;
import 'package:test/test.dart';

import 'surface/surface_inventory.dart';

void main() {
  final inventory = SurfaceInventory();
  final facade = File('lib/dart_monty.dart').absolute.uri;
  final expected =
      (jsonDecode(
                File('test/surface/names.json').readAsStringSync(),
              )
              as List<dynamic>)
          .cast<String>()
          .toSet();

  for (final web in [false, true]) {
    test('exact D2 exported names (${web ? "browser" : "native"})', () {
      final names = inventory.exported(facade, web: web).keys.toSet();
      final golden = {...expected};
      if (web) golden.remove('sandboxedFsHandler');
      expect(names, golden);
      expect(names, hasLength(web ? 59 : 60));
    });
  }

  test('exact retained dm member signatures', () {
    final declarations = inventory.exported(facade, web: false);
    [
      'Monty',
      'MontySession',
      'MontyValue',
      'MontyNone',
      'MontyError',
      'ResourceLimits',
      'OsHandler',
      'OsCallNotHandledException',
      'ExternalException',
    ].forEach(declarations.remove);
    final golden =
        jsonDecode(
              File('test/surface/members.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(memberSignatures(declarations), golden);
    expect(golden, hasLength(188));
    final headers =
        jsonDecode(
              File('test/surface/declarations.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(declarationSignatures(declarations), headers);
    expect(headers, hasLength(51));
  });

  test('MontyNone is usable through the facade', () {
    const dm.MontyValue none = dm.MontyNone();
    expect(none, isA<dm.MontyNone>());
    expect(none.dartValue, isNull);
  });

  test('only the main public library remains', () {
    expect(
      Directory('lib').listSync().whereType<File>().map(
        (file) => file.path.split(Platform.pathSeparator).lastOrNull!,
      ),
      unorderedEquals(['dart_monty.dart']),
    );
  });

  test('no private core imports', () async {
    final result = await Process.run('bash', [
      'tool/check_no_core_src_imports.sh',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
}
