// What the public libraries export from the OS-call layer.
//
// `composeOsHandlers`, `osArgString`, `PathOp` and `timeHandler` are internal:
// no file reachable through an `export` of a `lib/*.dart` library may declare
// them. The scan follows `export` directives, honours `show`/`hide`, and
// ignores `package:` URIs (core's own exports are core's business).
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart'
    show OsCallNotHandledException, OsHandler;
import 'package:test/test.dart';

import '_os_call.dart';

const _internal = ['composeOsHandlers', 'osArgString', 'PathOp', 'timeHandler'];

final _exportRe = RegExp(
  r'''export\s+'([^']+)'((?:\s+if\s*\([^)]*\)\s*'[^']+')*)\s*'''
  r'''(?:(show|hide)\s+([^;]+))?;''',
);
final _condRe = RegExp(r"""if\s*\([^)]*\)\s*'([^']+)'""");

/// Local files [lib] exports, with the names a `show`/`hide` clause limits.
Map<String, ({String? kind, Set<String> names})> _exports(String lib) {
  final out = <String, ({String? kind, Set<String> names})>{};
  void walk(String file) {
    final text = File(file).readAsStringSync();
    for (final m in _exportRe.allMatches(text)) {
      final targets = [
        m[1]!,
        ..._condRe.allMatches(m[2] ?? '').map((c) => c[1]!),
      ];
      final names = (m[4] ?? '')
          .split(',')
          .map((n) => n.trim())
          .where((n) => n.isNotEmpty)
          .toSet();
      for (final t in targets) {
        if (t.startsWith('package:') || t.startsWith('dart:')) continue;
        final path = Uri.file(file).resolve(t).toFilePath();
        if (out.containsKey(path)) continue;
        out[path] = (kind: m[3], names: names);
        if (m[3] == null) walk(path);
      }
    }
  }

  walk(lib);
  return out;
}

/// Whether [text] declares [name] at top level (a class-like or a function).
bool _declares(String text, String name) => RegExp(
  '^(?:(?:abstract |final |base |sealed )*'
  '(?:class|typedef|extension|enum|mixin)\\s+$name\\b'
  '|[A-Za-z][\\w<>?]*\\s+$name\\s*\\()',
  multiLine: true,
).hasMatch(text);

void main() {
  final libs = Directory('lib')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.path)
      .toList();

  test('there are public libraries to scan', () {
    expect(libs, contains('lib/dart_monty_bridge.dart'));
  });

  for (final name in _internal) {
    test('$name is not part of any public library', () {
      for (final lib in libs) {
        _exports(lib).forEach((file, clause) {
          final exposed = switch (clause.kind) {
            'show' => clause.names.contains(name),
            'hide' =>
              !clause.names.contains(name) &&
                  _declares(File(file).readAsStringSync(), name),
            _ => _declares(File(file).readAsStringSync(), name),
          };
          expect(exposed, isFalse, reason: '$lib exports $name via $file');
        });
      }
    });
  }

  test('the scan sees a declaration it should reject', () {
    // Guards the scan itself: it must flag the internal files.
    for (final (file, name) in [
      ('lib/src/os_call/os_handlers.dart', 'composeOsHandlers'),
      ('lib/src/os_call/os_handlers.dart', 'osArgString'),
      ('lib/src/os_call/path_op.dart', 'PathOp'),
    ]) {
      expect(_declares(File(file).readAsStringSync(), name), isTrue);
    }
  });

  test('OsHandler and the decline exception stay public', () {
    // Compile-time: this file imports only the public library, and the names
    // below must resolve through it.
    OsHandler decline() =>
        (operation, args, kwargs) => throw const OsCallNotHandledException();

    expectSyncDecline(() => rawCall(decline(), 'Path.exists'));
  });

  test('the default handler is chosen by conditional import', () {
    final text = File(
      'lib/src/os_call/default_os_handler.dart',
    ).readAsStringSync();

    expect(
      text,
      contains("export 'default_os_handler_stub.dart'"),
      reason: 'the stub is the unconditional branch',
    );
    expect(
      text,
      contains("if (dart.library.io) 'default_os_handler_native.dart'"),
    );
    expect(
      text,
      contains("if (dart.library.js_interop) 'default_os_handler_web.dart'"),
    );
  });
}
