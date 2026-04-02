@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests that validate Dart code blocks in README.md files
/// and example/example.dart files across all packages.
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

typedef BlockHandler =
    Future<void> Function(
      String block,
      NativeBindingsFfi bindings,
    );

/// Hand-written handlers keyed by `(readmePath, blockIndex)`.
final Map<(String, int), BlockHandler> _handlers = {
  // Root README.md — 9 dart blocks
  ('README.md', 0): _handleRootBlock0,
  ('README.md', 1): _handleRootBlock1,
  ('README.md', 2): _handleRootBlock2,
  ('README.md', 3): _handleRootBlock3,
  ('README.md', 4): _handleRootBlock4,
  ('README.md', 5): _handleRootBlock5,
  ('README.md', 6): _handleRootBlock6,
  ('README.md', 7): _handleRootBlock7,
  ('README.md', 8): _handleRootBlock8,

  // platform_interface/README.md
  ('packages/dart_monty_platform_interface/README.md', 0):
      _handlePlatformInterfaceBlock0,

  // ffi/README.md
  ('packages/dart_monty_ffi/README.md', 0): _handleFfiBlock0,

  // wasm/README.md
  ('packages/dart_monty_wasm/README.md', 0): _handleWasmBlock0,

  // web/README.md
  ('packages/dart_monty_web/README.md', 0): _handleWebBlock0,

  // native/README.md
  ('packages/dart_monty_native/README.md', 0): _handleNativeBlock0,
};

// ---------------------------------------------------------------------------
// Handlers — Root README
// ---------------------------------------------------------------------------

/// README.md block 0: Quick Start example.
Future<void> _handleRootBlock0(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains("run('2 + 2')"));
  expect(block, contains('result.value'));

  final monty = MontyFfi(bindings: bindings);
  final result = await monty.run('2 + 2');
  expect(result.value, 4);
  await monty.dispose();
}

/// README.md block 1: Web Quick Start (same API, structure-only).
Future<void> _handleRootBlock1(
  String block,
  NativeBindingsFfi _,
) async {
  expect(block, contains("run('2 + 2')"));
  expect(block, contains('result.value'));
}

/// README.md block 2: Usage section — simple execution + json + limits.
Future<void> _handleRootBlock2(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains("run('2 + 2')"));
  expect(block, contains('MontyLimits'));

  final monty = MontyFfi(bindings: bindings);

  // Simple execution
  final result = await monty.run('2 + 2');
  expect(result.value, 4);

  // With resource limits
  final limited = await monty.run(
    'sum(range(100))',
    limits: const MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
  );
  expect(limited.value, 4950);

  await monty.dispose();
}

/// README.md block 3: External function dispatch loop.
Future<void> _handleRootBlock3(
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

  progress = await monty.resume({'users': <String>[]});

  expect(progress, isA<MontyComplete>());
  final complete = progress as MontyComplete;
  expect(complete.result.value, {'users': <String>[]});

  await monty.dispose();
}

/// README.md block 4: Bridge (DefaultMontyBridge) — structure-only.
/// Requires dart_monty_bridge which is a separate package.
Future<void> _handleRootBlock4(String block, NativeBindingsFfi _) async {
  expect(block, contains('DefaultMontyBridge'));
  expect(block, contains('HostFunction'));
  expect(block, contains('BridgeToolCallResult'));
  expect(block, contains('callId'));
  expect(block, contains('bridge.dispose()'));
}

/// README.md block 5: MontyPlugin / PluginRegistry — structure-only.
Future<void> _handleRootBlock5(String block, NativeBindingsFfi _) async {
  expect(block, contains('MontyPlugin'));
  expect(block, contains('PluginRegistry'));
  expect(block, contains('namespace'));
}

/// README.md block 6: Error handling with sealed MontyError hierarchy.
Future<void> _handleRootBlock6(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains('MontyScriptError'));
  expect(block, contains('exception.excType'));
  expect(block, contains('exception.traceback'));
  expect(block, contains('frame.startLine'));

  final monty = MontyFfi(bindings: bindings);

  // Verify the pattern actually works.
  try {
    await monty.run('1 / 0');
    fail('Expected MontyScriptError');
  } on MontyError catch (e) {
    expect(e, isA<MontyScriptError>());
    final script = e as MontyScriptError;
    expect(script.excType, 'ZeroDivisionError');
    expect(script.exception.excType, 'ZeroDivisionError');
  }

  await monty.dispose();
}

/// README.md block 7: Cancellation (MontyCancelToken) — structure-only.
Future<void> _handleRootBlock7(String block, NativeBindingsFfi _) async {
  expect(block, contains('MontyCancelToken'));
  expect(block, contains('cancel()'));
}

/// README.md block 8: Stateful sessions.
Future<void> _handleRootBlock8(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains('MontySession'));
  expect(block, contains('x = 42'));
  expect(block, contains('session.clearState()'));
  expect(block, contains('session.dispose()'));
  // Verify no `await` before session.clearState() or session.dispose().
  expect(block, isNot(contains('await session.clearState()')));
  expect(block, isNot(contains('await session.dispose()')));

  final monty = MontyFfi(bindings: bindings);
  final session = MontySession(platform: monty);

  await session.run('x = 42');
  await session.run('y = x * 2');
  final result = await session.run('x + y');
  expect(result.value, 126);

  session
    ..clearState()
    ..dispose();
  await monty.dispose();
}

// ---------------------------------------------------------------------------
// Handlers — platform_interface/README.md
// ---------------------------------------------------------------------------

/// platform_interface/README.md block 0: MontyResult.fromJson.
Future<void> _handlePlatformInterfaceBlock0(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains('MontyResult.fromJson'));

  final result = MontyResult.fromJson(const {
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
// Handlers — ffi/README.md
// ---------------------------------------------------------------------------

/// ffi/README.md block 0: MontyFfi run + external function dispatch.
Future<void> _handleFfiBlock0(
  String block,
  NativeBindingsFfi bindings,
) async {
  expect(block, contains('MontyFfi'));
  expect(block, contains("run('2 + 2')"));

  final monty = MontyFfi(bindings: bindings);

  // Simple run
  final result = await monty.run('2 + 2');
  expect(result.value, 4);

  // External function dispatch
  var progress = await monty.start(
    'fetch("https://example.com")',
    externalFunctions: ['fetch'],
  );
  expect(progress, isA<MontyPending>());

  progress = await monty.resume({'status': 'ok'});
  expect(progress, isA<MontyComplete>());
  expect((progress as MontyComplete).result.value, {'status': 'ok'});

  await monty.dispose();
}

// ---------------------------------------------------------------------------
// Handlers — wasm/README.md (structure-only)
// ---------------------------------------------------------------------------

/// wasm/README.md block 0: verify structure contains expected API calls.
Future<void> _handleWasmBlock0(String block, NativeBindingsFfi _) async {
  expect(block, contains('MontyWasm'));
  expect(block, contains('run'));
}

// ---------------------------------------------------------------------------
// Handlers — web/README.md (structure-only)
// ---------------------------------------------------------------------------

/// web/README.md block 0: verify structure contains expected API calls.
Future<void> _handleWebBlock0(String block, NativeBindingsFfi _) async {
  expect(block, contains('MontyPlatform.instance'));
  expect(block, contains('run'));
}

// ---------------------------------------------------------------------------
// Handlers — native/README.md (structure-only)
// ---------------------------------------------------------------------------

/// native/README.md block 0: verify structure contains expected API calls.
Future<void> _handleNativeBlock0(String block, NativeBindingsFfi _) async {
  expect(block, contains('MontyPlatform.instance'));
  expect(block, contains('run'));
}

// ---------------------------------------------------------------------------
// Example file helpers
// ---------------------------------------------------------------------------

/// Read an example file relative to the repo root.
String _readExample(String repoRoot, String relativePath) =>
    File('$repoRoot/$relativePath').readAsStringSync();

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

  // -------------------------------------------------------------------
  // README.md validation
  // -------------------------------------------------------------------

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
        })
        .where((p) => File('$repoRoot/$p').existsSync()),
  ];

  for (final readmePath in readmePaths) {
    final file = File('$repoRoot/$readmePath');
    final blocks = _extractDartBlocks(file.readAsStringSync());

    // Safety net: every block must have a handler.
    test('$readmePath: all ${blocks.length} blocks have handlers', () {
      for (var i = 0; i < blocks.length; i++) {
        expect(
          _handlers.containsKey((readmePath, i)),
          isTrue,
          reason:
              '$readmePath block $i has no handler — add one to '
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

  // -------------------------------------------------------------------
  // example/example.dart validation
  // -------------------------------------------------------------------

  group('example/example.dart', () {
    // -- FFI: run the example patterns with real bindings --
    test('ffi/example/example.dart: run patterns', () async {
      final source = _readExample(
        repoRoot,
        'packages/dart_monty_ffi/example/example.dart',
      );
      // Verify the example contains expected patterns.
      expect(source, contains('MontyFfi'));
      expect(source, contains('NativeBindingsFfi'));
      expect(source, contains('MontyLimits'));
      expect(source, contains('externalFunctions'));
      expect(source, contains('MontyPending'));
      expect(source, contains('snapshot'));
      expect(source, contains('restore'));
      expect(source, contains('MontyException'));
      expect(source, contains('printOutput'));

      // Exercise the same patterns with real bindings.
      final monty = MontyFfi(bindings: bindings);

      // Simple run
      final result = await monty.run('2 + 2');
      expect(result.value, 4);

      // With limits
      final limited = await monty.run(
        'sum(range(100))',
        limits: const MontyLimits(
          timeoutMs: 5000,
          memoryBytes: 10 * 1024 * 1024,
          stackDepth: 100,
        ),
      );
      expect(limited.value, 4950);

      // External function dispatch
      var progress = await monty.start(
        'fetch("https://api.example.com/data")',
        externalFunctions: ['fetch'],
      );
      expect(progress, isA<MontyPending>());
      progress = await monty.resume({
        'users': ['alice', 'bob'],
      });
      expect(progress, isA<MontyComplete>());

      // Error handling — run() throws MontyScriptError on Python errors.
      try {
        await monty.run('1 / 0');
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        expect(e.excType, 'ZeroDivisionError');
      }

      // Print capture
      final printed = await monty.run('print("hello from Python")');
      expect(printed.printOutput, contains('hello from Python'));

      // Snapshot/restore — verify the example covers the pattern.
      // (Not exercised here; snapshot returns null in current native build.
      // The example shows the correct API usage pattern.)
      expect(source, contains('snapshot'));
      expect(source, contains('restore'));

      await monty.dispose();
    });

    // -- platform_interface: construct all types, verify fields --
    test(
      'platform_interface/example/example.dart: type construction',
      () async {
        final source = _readExample(
          repoRoot,
          'packages/dart_monty_platform_interface/example/example.dart',
        );
        expect(source, contains('MontyResult.fromJson'));
        expect(source, contains('MontyException'));
        expect(source, contains('MontyStackFrame'));
        expect(source, contains('MontyResourceUsage'));
        expect(source, contains('MontyLimits'));
        expect(source, contains('MontyPending'));
        expect(source, contains('MontyComplete'));
        expect(source, contains('MontyResolveFutures'));

        // Exercise the same type constructions.
        final result = MontyResult.fromJson(const {
          'value': 42,
          'usage': {
            'memory_bytes_used': 1024,
            'time_elapsed_ms': 5,
            'stack_depth_used': 2,
          },
        });
        expect(result.value, 42);
        expect(result.isError, isFalse);

        final errorResult = MontyResult.fromJson(const {
          'error': {
            'message': 'division by zero',
            'exc_type': 'ZeroDivisionError',
            'filename': '<expr>',
            'line_number': 1,
            'column_number': 2,
          },
          'usage': {
            'memory_bytes_used': 512,
            'time_elapsed_ms': 1,
            'stack_depth_used': 1,
          },
        });
        expect(errorResult.isError, isTrue);
        expect(errorResult.error!.excType, 'ZeroDivisionError');

        const frame = MontyStackFrame(
          filename: 'script.py',
          startLine: 5,
          startColumn: 10,
          frameName: '<module>',
          previewLine: '    return x + 1',
        );
        expect(frame.filename, 'script.py');
        expect(frame.startLine, 5);
        expect(frame.frameName, '<module>');

        const usage = MontyResourceUsage(
          memoryBytesUsed: 2048,
          timeElapsedMs: 10,
          stackDepthUsed: 3,
        );
        expect(usage.memoryBytesUsed, 2048);

        const limits = MontyLimits(
          timeoutMs: 5000,
          memoryBytes: 10 * 1024 * 1024,
          stackDepth: 100,
        );
        expect(limits.timeoutMs, 5000);

        // Pattern matching on sealed type.
        const pending = MontyPending(
          functionName: 'fetch',
          arguments: ['https://api.example.com/data'],
          kwargs: {'timeout': 30},
          callId: 1,
        );
        expect(pending.functionName, 'fetch');
        expect(pending.kwargs, {'timeout': 30});

        const complete = MontyComplete(
          result: MontyResult(
            value: 42,
            usage: MontyResourceUsage(
              memoryBytesUsed: 1024,
              timeElapsedMs: 5,
              stackDepthUsed: 2,
            ),
          ),
        );
        expect(complete.result.value, 42);

        const futures = MontyResolveFutures(pendingCallIds: [1, 2, 3]);
        expect(futures.pendingCallIds, [1, 2, 3]);

        // Exhaustive switch (compile-time guarantee).
        for (final progress in [pending, complete, futures]) {
          switch (progress) {
            case MontyPending(:final functionName):
              expect(functionName, 'fetch');
            case MontyComplete(:final result):
              expect(result.value, 42);
            case MontyResolveFutures(:final pendingCallIds):
              expect(pendingCallIds, hasLength(3));
          }
        }
      },
    );

    // -- WASM: structure-only --
    test('wasm/example/example.dart: structure', () {
      final source = _readExample(
        repoRoot,
        'packages/dart_monty_wasm/example/example.dart',
      );
      expect(source, contains('MontyWasm'));
      expect(source, contains('WasmBindingsJs'));
      expect(source, contains('MontyLimits'));
      expect(source, contains('externalFunctions'));
      expect(source, contains('MontyPending'));
      expect(source, contains('MontyScriptError'));
    });

    // -- web: structure-only --
    test('web/example/example.dart: structure', () {
      final source = _readExample(
        repoRoot,
        'packages/dart_monty_web/example/example.dart',
      );
      expect(source, contains('MontyPlatform.instance'));
      expect(source, contains("run('2 + 2')"));
    });

    // -- native: structure-only --
    test('native/example/example.dart: structure', () {
      final source = _readExample(
        repoRoot,
        'packages/dart_monty_native/example/example.dart',
      );
      expect(source, contains('MontyPlatform.instance'));
      expect(source, contains("run('2 + 2')"));
    });

    // -- root example: structure-only --
    test('example/example.dart: structure', () {
      final source = _readExample(repoRoot, 'example/example.dart');
      expect(source, contains('Monty()'));
      expect(source, contains('MontyLimits'));
      expect(source, contains('MontyScriptError'));
    });
  });
}
