// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print
/// Interactive VFS Demo — shows Python↔VFS round-trip in the browser.
///
/// Compiled to JS, exposes functions to the HTML UI via window.VfsDemo.
/// Each run feeds the code to a fresh session whose OS handler is an
/// in-memory filesystem (core `OSAccess` and `MemoryFile`); every OS
/// call it answers is logged to the page. Clock calls (`date.today`,
/// `datetime.now`) are answered by the session's own OS policy.
///
/// Build:
///   dart compile js example/web/bin/vfs_demo.dart \
///     -o example/web/web/vfs_demo.dart.js
library;

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show
        MemoryFile,
        MontyBool,
        MontyBytes,
        MontyList,
        MontyPath,
        MontyString,
        OSAccess;

import 'package:web_example/demo_pool.dart';
import 'package:web_example/demo_ready.dart';

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

late final Monty _pool;
OSAccess _vfs = OSAccess();
OsHandler _fs = _vfs.call;
final _osCallLog = <Map<String, dynamic>>[];

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

/// [_fs], logging each call it answers to the page.
Future<MontyValue> _loggedOsCall(
  String op,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) async {
  final sw = Stopwatch()..start();
  final result = await _fs(op, args, kwargs);
  sw.stop();

  final logEntry = {
    'op': op,
    'args': args.map((a) => '${a.dartValue}').toList(),
    'result': _summarize(result.dartValue),
    'durationMs': sw.elapsedMilliseconds,
  };
  _osCallLog.add(logEntry);

  // Notify the HTML UI in real-time.
  try {
    _jsOnOsCall(jsonEncode(logEntry).toJS);
  } on Object catch (_) {
    // _onOsCall not defined — OK in headless mode.
  }

  return result;
}

String _summarize(Object? value) {
  if (value == null) return 'null';
  final s = value.toString();
  return s.length > 80 ? '${s.substring(0, 77)}...' : s;
}

/// Runs [code] on a fresh session over a fresh VFS holding the staged
/// files; the value, or the Python error as text.
Future<({Object? value, String? error})> _runWithVfs(String code) async {
  _osCallLog.clear();
  _vfs = OSAccess(
    files: [for (final e in _stagedFiles.entries) MemoryFile(e.key, e.value)],
  );
  _fs = _vfs.call;

  try {
    final value = await _pool.withSession(
      (session) => session.feedRun(code, os: _loggedOsCall),
    );

    return (value: value.dartValue, error: null);
  } on MontyError catch (e) {
    return (
      value: null,
      error: '${e.exception.excType}: ${e.exception.message ?? ''}',
    );
  }
}

// ---------------------------------------------------------------------------
// File staging (mount files before run)
// ---------------------------------------------------------------------------

final _stagedFiles = <String, String>{};

Future<void> _writeVfsFile(String path, String content) async {
  final parent = path.substring(0, path.lastIndexOf('/'));
  await _vfs.call(
    'Path.mkdir',
    [MontyPath(parent.isEmpty ? '/' : parent)],
    {'parents': const MontyBool(true), 'exist_ok': const MontyBool(true)},
  );
  await _vfs
      .call('Path.write_text', [MontyPath(path), MontyString(content)], {});
}

Future<void> _mountFile(String path, String content) async {
  _stagedFiles[path] = content;
  await _writeVfsFile(path, content);
  // Refresh VFS panel immediately.
  final files = await _collectFiles();
  try {
    _jsOnFilesChanged(jsonEncode(files).toJS);
  } on Object catch (_) {}
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

  return jsonEncode(
    {
      'ok': result.error == null,
      if (result.value != null) 'value': result.value,
      if (result.error != null) 'error': result.error,
      'osCallLog': _osCallLog,
      'files': files,
    },
    toEncodable: (value) => '$value',
  );
}

Future<List<Map<String, dynamic>>> _collectFiles() async {
  final files = <Map<String, dynamic>>[];
  Future<void> walk(String dirPath) async {
    try {
      final entries = await _listDir(dirPath);
      for (final entry in entries) {
        final isFile = await _vfs.call('Path.is_file', [MontyPath(entry)], {});
        if (isFile == const MontyBool(true)) {
          // Binary files (e.g. blob.bin with 0xff) aren't valid UTF-8, so read
          // bytes first and only decode as text when it round-trips cleanly —
          // a binary file must not abort the whole VFS walk.
          final bytes =
              (await _vfs.call('Path.read_bytes', [MontyPath(entry)], {})
                      as MontyBytes)
                  .value;
          String? text;
          try {
            text = utf8.decode(bytes);
          } on FormatException {
            text = null; // binary
          }
          files.add({
            'path': entry,
            'type': 'file',
            'size': bytes.length,
            'preview': text == null
                ? '<binary ${bytes.length}B>'
                : (text.length > 200 ? '${text.substring(0, 197)}...' : text),
          });
        } else {
          files.add({'path': entry, 'type': 'dir'});
          await walk(entry);
        }
      }
    } on Object catch (_) {
      // Not a directory or doesn't exist.
    }
  }

  // Walk from /sandbox root.
  await walk('/sandbox');
  return files;
}

Future<List<String>> _listDir(String path) async {
  try {
    final r = await _fs('Path.iterdir', [MontyPath(path)], const {});
    if (r is MontyList) {
      return [
        for (final e in r.items)
          if (e is MontyPath) e.value else '${e.dartValue}',
      ];
    }
    return [];
  } on Object catch (_) {
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
      unawaited(_mountFile(path.toDart, content.toDart));
    }).toJS,
    'clearMounts': _clearMounts.toJS,
  }.jsify();
  _vfsDemo = api! as JSObject;

  try {
    _pool = await startDemoPool();
  } on Object catch (e) {
    print('VFS_DEMO_ERROR: worker start failed: $e');
    montyDemoFailed('vfs_demo', 'Monty.start failed: $e');
    return;
  }

  print('VFS Demo ready');
  // Raised after the worker pool started.
  montyDemoReady('vfs_demo');
  try {
    _jsOnReady();
  } on Object catch (_) {
    // _onReady not defined — OK in headless mode.
  }
}
