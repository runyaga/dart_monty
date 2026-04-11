// Standalone JS-compiled runner, not a package:test file.
// ignore_for_file: avoid_print, unnecessary_raw_strings, lines_longer_than_80_chars
/// WASM VFS Integration Test — proves full Python→WASM→OsCall→VFS→Python.
///
/// Compiled to JS, runs in headless Chrome with COOP/COEP headers.
/// Handles Path.* os_calls locally using MemoryFsOsCallHandler.
///
/// Build:
///   dart compile js test/wasm/integration/vfs_runner.dart \
///     -o test/wasm/integration/web/vfs_runner.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

// ---------------------------------------------------------------------------
// JS interop bindings for DartMontyBridge (instance-based)
// ---------------------------------------------------------------------------

@JS('DartMontyBridge')
extension type _DartMontyBridge._(JSObject _) implements JSObject {
  external _DartMontyBridge();
  external JSPromise<JSBoolean> init();
  external JSPromise<JSString> start(JSString code);
  external JSPromise<JSString> resume(JSString valueJson);
  external JSPromise<JSString> resumeWithError(JSString errorJson);
}

late _DartMontyBridge _bridge;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void _pass(String name) => print('VFS_PASS:$name');
void _fail(String name, String reason) => print('VFS_FAIL:$name:$reason');

// ---------------------------------------------------------------------------
// VFS handler — runs entirely in Dart (compiled to JS)
// ---------------------------------------------------------------------------

/// Shared VFS instance across all tests. Reset per test.
late MemoryFsOsCallHandler _vfs;
late TimeOsCallHandler _time;

/// Known os_call prefixes.
bool _isOsCall(String? functionName) {
  if (functionName == null) return false;
  return functionName.startsWith('Path.') ||
      functionName.startsWith('date.') ||
      functionName.startsWith('datetime.');
}

/// Handles an os_call by dispatching to the appropriate handler.
/// Returns the JSON-encoded result to pass to resume().
Future<Object?> _handleOsCall(Map<String, dynamic> state) async {
  final op = state['functionName'] as String;
  final rawArgs = state['args'] as List? ?? [];

  // Parse args from raw JSON values into MontyValue.
  final args = rawArgs.map(MontyValue.fromJson).toList();

  // Parse kwargs if present.
  Map<String, MontyValue>? kwargs;
  final rawKwargs = state['kwargs'] as Map<String, dynamic>?;
  if (rawKwargs != null) {
    kwargs = rawKwargs.map((k, v) => MapEntry(k, MontyValue.fromJson(v)));
  }

  final call = MontyOsCall(
    operationName: op,
    arguments: args,
    kwargs: kwargs,
  );

  if (op.startsWith('Path.')) {
    return _vfs.handle(call);
  } else if (op.startsWith('date.') || op.startsWith('datetime.')) {
    return _time.handle(call);
  }
  throw UnsupportedError('Unhandled os_call: $op');
}

/// Runs Python code through the WASM bridge, handling os_calls locally.
///
/// Returns the final result map from the bridge.
Future<Map<String, dynamic>> _runWithVfs(String code) async {
  var state = _parse(
    (await _bridge.start(code.toJS).toDart).toDart,
  );

  while (state['state'] != 'complete') {
    if (state['ok'] != true) return state;

    if (state['state'] == 'pending' &&
        _isOsCall(state['functionName'] as String?)) {
      try {
        final result = await _handleOsCall(state);
        state = _parse(
          (await _bridge.resume(jsonEncode(result).toJS).toDart).toDart,
        );
      } on Object catch (e) {
        state = _parse(
          (await _bridge
                  .resumeWithError(
                    jsonEncode(e.toString()).toJS,
                  )
                  .toDart)
              .toDart,
        );
      }
    } else {
      _fail('loop', 'Unexpected state: ${jsonEncode(state)}');
      return state;
    }
  }

  return state;
}

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------

/// Test 1: Write a file with pathlib, read it back.
Future<void> _testWriteRead() async {
  _vfs = MemoryFsOsCallHandler();

  const code = r"""
from pathlib import Path
Path('/sandbox/test.txt').write_text('hello from WASM')
Path('/sandbox/test.txt').read_text()
""";

  final result = await _runWithVfs(code);
  if (result['ok'] == true && result['value'] == 'hello from WASM') {
    _pass('write_read');
  } else {
    _fail('write_read', 'Expected "hello from WASM", got ${result['value']}');
  }
}

/// Test 2: Path.exists on missing file returns False.
Future<void> _testPathExists() async {
  _vfs = MemoryFsOsCallHandler();

  const code = r"""
from pathlib import Path
Path('/sandbox/nope.txt').exists()
""";

  final result = await _runWithVfs(code);
  if (result['ok'] == true && result['value'] == false) {
    _pass('path_exists_false');
  } else {
    _fail('path_exists_false', 'Expected false, got ${result['value']}');
  }
}

/// Test 3: mkdir + iterdir round-trip.
Future<void> _testMkdirIterdir() async {
  _vfs = MemoryFsOsCallHandler();

  const code = r"""
from pathlib import Path
d = Path('/sandbox/mydir')
d.mkdir(parents=True)
Path('/sandbox/mydir/a.txt').write_text('a')
Path('/sandbox/mydir/b.txt').write_text('b')
sorted([p.name for p in d.iterdir()])
""";

  final result = await _runWithVfs(code);
  if (result['ok'] == true) {
    final value = result['value'];
    if (value is List && value.length == 2) {
      _pass('mkdir_iterdir');
    } else {
      _fail('mkdir_iterdir', 'Expected [a.txt, b.txt], got $value');
    }
  } else {
    _fail('mkdir_iterdir', 'Error: ${result['error']}');
  }
}

/// Test 4: Write JSON config, read and parse it.
Future<void> _testJsonConfig() async {
  _vfs = MemoryFsOsCallHandler();

  // Pre-populate VFS from Dart side.
  _vfs.writeFile('/sandbox/config.json', '{"api_key": "abc123", "retries": 3}');

  const code = r"""
import json
from pathlib import Path
config = json.loads(Path('/sandbox/config.json').read_text())
{'key': config['api_key'], 'retries': config['retries']}
""";

  final result = await _runWithVfs(code);
  if (result['ok'] == true) {
    final value = result['value'] as Map?;
    if (value != null && value['key'] == 'abc123' && value['retries'] == 3) {
      _pass('json_config');
    } else {
      _fail('json_config', 'Expected {key: abc123, retries: 3}, got $value');
    }
  } else {
    _fail('json_config', 'Error: ${result['error']}');
  }
}

/// Test 5: Data pipeline — read input, process, write output, return stats.
Future<void> _testDataPipeline() async {
  _vfs = MemoryFsOsCallHandler();

  // Pre-populate input from Dart.
  _vfs.writeFile(
    '/sandbox/input.csv',
    'name,score\nalice,95\nbob,87\ncarol,92',
  );

  const code = r"""
from pathlib import Path
lines = Path('/sandbox/input.csv').read_text().strip().split('\n')
rows = [l.split(',') for l in lines[1:]]
scores = [int(r[1]) for r in rows]
avg = sum(scores) / len(scores)
Path('/sandbox/output.txt').write_text(f'avg:{avg:.1f}')
{'count': len(rows), 'top': max(rows, key=lambda r: int(r[1]))[0]}
""";

  final result = await _runWithVfs(code);
  if (result['ok'] == true) {
    final value = result['value'] as Map?;
    if (value != null && value['count'] == 3 && value['top'] == 'alice') {
      // Also verify the output file was written to VFS.
      final output = _vfs.readFile('/sandbox/output.txt');
      if (output == 'avg:91.3') {
        _pass('data_pipeline');
      } else {
        _fail(
          'data_pipeline',
          'output.txt: expected "avg:91.3", got "$output"',
        );
      }
    } else {
      _fail('data_pipeline', 'Expected {count: 3, top: alice}, got $value');
    }
  } else {
    _fail('data_pipeline', 'Error: ${result['error']}');
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== WASM VFS Integration Tests ===');

  _bridge = _DartMontyBridge();
  _time = TimeOsCallHandler();
  final ok = (await _bridge.init().toDart).toDart;
  if (!ok) {
    print('VFS_ERROR:Init failed');
    print('VFS_DONE');
    return;
  }

  await _testWriteRead();
  await _testPathExists();
  await _testMkdirIterdir();
  await _testJsonConfig();
  await _testDataPipeline();

  print('VFS_DONE');
}
