// Replacement for the deleted handler-only write tests: actual Python open
// modes, UTF-8 and binary payloads, namespace state and cap boundaries.
import 'dart:convert';

import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:test/test.dart';

import '../../integration/_workspace_harness.dart';

void main() {
  final h = WorkspaceHarness()..install();
  const methods = ['text', 'bytes', 'w', 'wb', 'a', 'ab'];
  const payloads = ['ascii', 'é', '😀', 'line\nnext', '\u0000byte'];
  const initialStates = <String?>[null, '', 'seed'];
  for (final method in methods) {
    for (final payload in payloads) {
      for (final initial in initialStates) {
        for (final accepts in [true, false]) {
          final label = jsonEncode([method, payload, initial, accepts]);
          test('real workspace write boundary $label', () async {
            final bytes = utf8.encode(payload).length;
            final w = Workspace(
              files: {'out': ?initial},
              writeBytesLimit: accepts ? bytes : bytes - 1,
            );
            addTearDown(w.dispose);
            final text = jsonEncode(payload);
            final binary = method == 'bytes' || method.endsWith('b');
            final value = binary ? '$text.encode()' : text;
            final statement = switch (method) {
              'text' => "Path('out').write_text($value)",
              'bytes' => "Path('out').write_bytes($value)",
              _ => "with open('out', '$method') as f:\n    f.write($value)",
            };
            if (accepts) {
              await h.run(w, statement);
              final expected = method.startsWith('a')
                  ? '${initial ?? ''}$payload'
                  : payload;
              expect(await h.run(w, "Path('out').read_text()"), expected);
              expect(w.writeBytes, bytes);
              expect(w.memoryUsage, utf8.encode(expected).length + 128);
            } else {
              // Open is an independently accepted mutation: w truncates,
              // a creates. The later rejected payload must not undo the open.
              final indented = statement.replaceAll('\n', '\n    ');
              expect(
                await h.caught(w, indented),
                'OSError: Workspace write byte limit exceeded',
              );
              final exists =
                  initial != null || method != 'text' && method != 'bytes';
              expect(await h.run(w, "Path('out').exists()"), exists);
              final expected = method.startsWith('w') ? '' : initial ?? '';
              if (exists) {
                expect(await h.run(w, "Path('out').read_text()"), expected);
              }
              expect(w.writeBytes, 0);
              expect(
                w.memoryUsage,
                (exists ? utf8.encode(expected).length + 64 : 0) + 64,
              );
            }
          });
        }
      }
    }
  }
}
