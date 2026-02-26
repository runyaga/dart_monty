@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests that validate Dart code blocks in README.md files.
///
/// Extracts fenced ```dart blocks from every README and runs a hand-written
/// handler for each one. Unknown blocks cause test failures so new examples
/// are always validated.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_ffi
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test --tags=integration test/integration/readme_doctest.dart
/// ```

// ---------------------------------------------------------------------------
// Markdown extraction
// ---------------------------------------------------------------------------

final _dartFence = RegExp(
  r'```dart\s*\n(.*?)```',
  multiLine: true,
  dotAll: true,
);

List<String> _extractDartBlocks(String markdown) =>
    _dartFence.allMatches(markdown).map((m) => m.group(1)!.trim()).toList();

// ---------------------------------------------------------------------------
// Registry: (relative path from repo root) -> handler per block index
// ---------------------------------------------------------------------------

typedef BlockHandler = Future<void> Function(
  String block,
  NativeBindingsFfi bindings,
);

/// READMEs that are known to contain zero Dart blocks.
///
/// If any of these gain blocks, the safety-net test fails — forcing you to
/// add a handler.
const _knownEmpty = {
  'packages/dart_monty_ffi/README.md',
  'packages/dart_monty_wasm/README.md',
  'packages/dart_monty_web/README.md',
  'packages/dart_monty_native/README.md',
};

/// Hand-written handlers keyed by `(readmePath, blockIndex)`.
final Map<(String, int), BlockHandler> _handlers = {
  // README.md block 0 — simple execution + resource limits
  ('README.md', 0): _handleRootBlock0,

  // README.md block 1 — external function dispatch loop
  ('README.md', 1): _handleRootBlock1,

  // README.md block 2 — stateful sessions
  ('README.md', 2): _handleRootBlock2,

  // packages/dart_monty_platform_interface/README.md block 0 — fromJson
  ('packages/dart_monty_platform_interface/README.md', 0):
      _handlePlatformInterfaceBlock0,
};

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// README.md block 0: simple execution + resource limits.
///
/// The README calls `fib(30)` but Monty has no built-in fib.
/// We validate the *pattern* — `run()` works with and without limits.
Future<void> _handleRootBlock0(
  String block,
  NativeBindingsFfi bindings,
) async {
  // Verify the block looks like what we expect.
  expect(block, contains("run('2 + 2')"));
  expect(block, contains('MontyLimits'));

  final monty = MontyFfi(bindings: bindings);

  // Simple execution
  final result = await monty.run('2 + 2');
  expect(result.value, 4);

  // With resource limits — define fib so the code actually runs.
  final limited = await monty.run(
    'def fib(n):\n'
    '  if n < 2:\n'
    '    return n\n'
    '  return fib(n - 1) + fib(n - 2)\n'
    'fib(10)',
    limits: MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
  );
  expect(limited.value, 55);

  await monty.dispose();
}

/// README.md block 1: external function dispatch loop.
Future<void> _handleRootBlock1(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains('externalFunctions'));
  expect(block, contains('MontyPending'));

  final monty = MontyFfi(bindings: bindings);

  var progress = await monty.start(
    'fetch("https://api.example.com/users")',
    externalFunctions: ['fetch'],
  );

  expect(progress, isA<MontyPending>());
  final pending = progress as MontyPending;
  expect(pending.functionName, 'fetch');
  expect(pending.arguments, ['https://api.example.com/users']);

  // Resume with mock data (README uses http.get — we just provide a value).
  progress = await monty.resume({'users': []});

  expect(progress, isA<MontyComplete>());
  final complete = progress as MontyComplete;
  expect(complete.result.value, {'users': []});

  await monty.dispose();
}

/// README.md block 2: stateful sessions.
Future<void> _handleRootBlock2(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains('MontySession'));
  expect(block, contains('x = 42'));

  final monty = MontyFfi(bindings: bindings);
  final session = MontySession(platform: monty);

  await session.run('x = 42');
  await session.run('y = x * 2');
  final result = await session.run('x + y');
  expect(result.value, 126);

  session.clearState();
  session.dispose();
  await monty.dispose();
}

/// platform_interface/README.md block 0: MontyResult.fromJson.
Future<void> _handlePlatformInterfaceBlock0(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains('MontyResult.fromJson'));

  final result = MontyResult.fromJson({
    'value': 42,
    'usage': {
      'memory_bytes_used': 1024,
      'time_elapsed_ms': 5,
      'stack_depth_used': 2,
    },
  });

  expect(result.value, 42);
  expect(result.usage.memoryBytesUsed, 1024);
  expect(result.usage.timeElapsedMs, 5);
  expect(result.usage.stackDepthUsed, 2);
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

void main() {
  late NativeBindingsFfi bindings;

  // Resolve repo root from this file's location:
  // packages/dart_monty_ffi/test/integration/ → ../../..
  final repoRoot = Directory('${Directory.current.path}/../..').absolute.path;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  // Discover all README.md files.
  final readmePaths = <String>[
    'README.md',
    ...Directory('$repoRoot/packages')
        .listSync()
        .whereType<Directory>()
        .where(
          (d) =>
              !d.path.contains('node_modules') &&
              !d.path.contains('.claude') &&
              !d.path.contains('spike'),
        )
        .map((d) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      return 'packages/$name/README.md';
    }).where((p) => File('$repoRoot/$p').existsSync()),
  ];

  for (final readmePath in readmePaths) {
    final file = File('$repoRoot/$readmePath');
    final blocks = _extractDartBlocks(file.readAsStringSync());

    if (_knownEmpty.contains(readmePath)) {
      test('$readmePath: still has no Dart blocks', () {
        expect(
          blocks,
          isEmpty,
          reason: '$readmePath gained Dart blocks — add handlers to '
              'readme_doctest.dart',
        );
      });
      continue;
    }

    // Safety net: every block must have a handler.
    test('$readmePath: all ${blocks.length} blocks have handlers', () {
      for (var i = 0; i < blocks.length; i++) {
        expect(
          _handlers.containsKey((readmePath, i)),
          isTrue,
          reason: '$readmePath block $i has no handler — add one to '
              'readme_doctest.dart',
        );
      }
    });

    // Run each handler.
    for (var i = 0; i < blocks.length; i++) {
      final handler = _handlers[(readmePath, i)];
      if (handler == null) continue;

      test('$readmePath block $i', () async {
        await handler(blocks[i], bindings);
      });
    }
  }
}
