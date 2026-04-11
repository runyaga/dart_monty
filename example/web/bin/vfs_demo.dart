// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print, unnecessary_raw_strings, lines_longer_than_80_chars
/// Interactive VFS Demo — shows Python↔VFS round-trip in the browser.
///
/// Compiled to JS, exposes functions to the HTML UI via window.VfsDemo.
///
/// Build:
///   dart compile js test/wasm/integration/vfs_demo.dart \
///     -o test/wasm/integration/web/vfs_demo.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

// ---------------------------------------------------------------------------
// JS interop — WASM bridge (static method API on window.DartMontyBridge)
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.start')
external JSPromise<JSString> _bridgeStart(JSString code);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _bridgeResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _bridgeResumeWithError(JSString errorJson);

// ---------------------------------------------------------------------------
// JS interop — expose API to HTML
// ---------------------------------------------------------------------------

@JS('window.VfsDemo')
external set _vfsDemo(JSObject obj);

@JS('window._onOsCall')
external void _jsOnOsCall(JSString jsonPayload);

@JS('window._onReady')
external void _jsOnReady();

@JS('window._onFilesChanged')
external void _jsOnFilesChanged(JSString filesJson);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

var _vfs = MemoryFsOsCallHandler();
late TimeOsCallHandler _time;
final _osCallLog = <Map<String, dynamic>>[];

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

bool _isOsCall(String? fn) {
  if (fn == null) return false;
  return fn.startsWith('Path.') ||
      fn.startsWith('date.') ||
      fn.startsWith('datetime.');
}

Future<Object?> _handleOsCall(Map<String, dynamic> state) async {
  final op = state['functionName'] as String;
  final rawArgs = state['args'] as List? ?? [];
  final args = rawArgs.map(MontyValue.fromJson).toList();

  Map<String, MontyValue>? kwargs;
  final rawKwargs = state['kwargs'] as Map<String, dynamic>?;
  if (rawKwargs != null) {
    kwargs = rawKwargs.map((k, v) => MapEntry(k, MontyValue.fromJson(v)));
  }

  final call = MontyOsCall(operationName: op, arguments: args, kwargs: kwargs);

  final sw = Stopwatch()..start();
  Object? result;

  if (op.startsWith('Path.')) {
    result = await _vfs.handle(call);
  } else if (op.startsWith('date.') || op.startsWith('datetime.')) {
    result = await _time.handle(call);
  } else {
    throw UnsupportedError('Unhandled os_call: $op');
  }

  sw.stop();

  // Log the os_call for the UI.
  final logEntry = {
    'op': op,
    'args': rawArgs.map((a) => a.toString()).toList(),
    'result': _summarize(result),
    'durationMs': sw.elapsedMilliseconds,
  };
  _osCallLog.add(logEntry);

  // Notify the HTML UI in real-time.
  try {
    _jsOnOsCall(jsonEncode(logEntry).toJS);
  } catch (_) {
    // _onOsCall not defined — OK in headless mode.
  }

  return result;
}

String _summarize(Object? value) {
  if (value == null) return 'null';
  final s = value.toString();
  return s.length > 80 ? '${s.substring(0, 77)}...' : s;
}

Future<Map<String, dynamic>> _runWithVfs(String code) async {
  _osCallLog.clear();
  _vfs = MemoryFsOsCallHandler();
  _time = TimeOsCallHandler();

  // Mount any pre-staged files (set by mountFile before run).
  for (final entry in _stagedFiles.entries) {
    _vfs.writeFile(entry.key, entry.value);
  }

  var state = _parse((await _bridgeStart(code.toJS).toDart).toDart);

  while (state['state'] != 'complete') {
    if (state['ok'] != true) return state;

    if (state['state'] == 'os_call' ||
        (state['state'] == 'pending' &&
            _isOsCall(state['functionName'] as String?))) {
      try {
        final result = await _handleOsCall(state);
        state = _parse(
          (await _bridgeResume(jsonEncode(result).toJS).toDart).toDart,
        );
      } on Object catch (e) {
        state = _parse(
          (await _bridgeResumeWithError(
            jsonEncode(e.toString()).toJS,
          ).toDart).toDart,
        );
      }
    } else {
      return {'ok': false, 'error': 'Unexpected state: ${state['state']}'};
    }
  }

  return state;
}

// ---------------------------------------------------------------------------
// File staging (mount files before run)
// ---------------------------------------------------------------------------

final _stagedFiles = <String, String>{};

Future<void> _mountFile(String path, String content) async {
  _stagedFiles[path] = content;
  _vfs.writeFile(path, content);
  // Refresh VFS panel immediately.
  final files = await _collectFiles();
  try {
    _jsOnFilesChanged(jsonEncode(files).toJS);
  } catch (_) {}
}

void _clearMounts() {
  _stagedFiles.clear();
}

// ---------------------------------------------------------------------------
// API exposed to HTML via window.VfsDemo
// ---------------------------------------------------------------------------

/// Returns a JSON object:
/// { ok, value?, error?, osCallLog, files }
Future<String> _apiRun(String code) async {
  final result = await _runWithVfs(code);

  // Collect VFS file tree after execution.
  final files = await _collectFiles();

  return jsonEncode({
    'ok': result['ok'],
    if (result['value'] != null) 'value': result['value'],
    if (result['error'] != null) 'error': result['error'],
    'osCallLog': _osCallLog,
    'files': files,
  });
}

Future<List<Map<String, dynamic>>> _collectFiles() async {
  final files = <Map<String, dynamic>>[];
  Future<void> walk(String dirPath) async {
    try {
      final entries = await _listDir(dirPath);
      for (final entry in entries) {
        if (_vfs.exists(entry)) {
          // Check if it's a file by trying to read it.
          try {
            final content = _vfs.readFile(entry);
            files.add({
              'path': entry,
              'type': 'file',
              'size': content.length,
              'preview': content.length > 200
                  ? '${content.substring(0, 197)}...'
                  : content,
            });
          } catch (_) {
            // It's a directory.
            files.add({'path': entry, 'type': 'dir'});
            await walk(entry);
          }
        }
      }
    } catch (_) {
      // Not a directory or doesn't exist.
    }
  }

  // Walk from /sandbox root.
  await walk('/sandbox');
  return files;
}

Future<List<String>> _listDir(String path) async {
  try {
    final call = MontyOsCall(
      operationName: 'Path.iterdir',
      arguments: [MontyString(path)],
    );
    final r = await _vfs.handle(call);
    if (r is List) {
      return r.map((e) => e is MontyPath ? e.value : e.toString()).toList();
    }
    return [];
  } catch (_) {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Main — wire up JS API and initialize
// ---------------------------------------------------------------------------

Future<void> main() async {
  // Expose API to HTML.
  final api = <String, JSFunction>{
    'run': ((JSString code) => _apiRun(
      code.toDart,
    ).then((r) => r.toJS).toJS).toJS,
    'mountFile': ((JSString path, JSString content) {
      _mountFile(path.toDart, content.toDart);
    }).toJS,
    'clearMounts': (() => _clearMounts()).toJS,
  }.jsify();
  _vfsDemo = api as JSObject;

  // Initialize WASM bridge (static method API).
  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    print('VFS_DEMO_ERROR: WASM init failed');
    return;
  }

  print('VFS Demo ready');
  try {
    _jsOnReady();
  } catch (_) {
    // _onReady not defined — OK in headless mode.
  }
}
