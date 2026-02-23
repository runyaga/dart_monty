import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_monty_desktop/src/desktop_bindings.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

// =============================================================================
// Message types (private sealed classes)
// =============================================================================

/// Initial configuration sent from main → Isolate at spawn time.
final class _InitMessage {
  const _InitMessage(this.mainSendPort, {this.libraryPath});
  final SendPort mainSendPort;
  final String? libraryPath;
}

/// Message sent from the Isolate once it's ready.
final class _ReadyMessage {
  const _ReadyMessage(this.sendPort);
  final SendPort sendPort;
}

/// Base request type sent from main → Isolate.
sealed class _Request {
  const _Request(this.id);
  final int id;
}

final class _RunRequest extends _Request {
  const _RunRequest(super.id, this.code, {this.limits, this.scriptName});
  final String code;
  final MontyLimits? limits;
  final String? scriptName;
}

final class _StartRequest extends _Request {
  const _StartRequest(
    super.id,
    this.code, {
    this.externalFunctions,
    this.limits,
    this.scriptName,
  });
  final String code;
  final List<String>? externalFunctions;
  final MontyLimits? limits;
  final String? scriptName;
}

final class _ResumeRequest extends _Request {
  const _ResumeRequest(super.id, this.returnValue);
  final Object? returnValue;
}

final class _ResumeWithErrorRequest extends _Request {
  const _ResumeWithErrorRequest(super.id, this.errorMessage);
  final String errorMessage;
}

final class _SnapshotRequest extends _Request {
  const _SnapshotRequest(super.id);
}

final class _RestoreRequest extends _Request {
  const _RestoreRequest(super.id, this.data);
  final Uint8List data;
}

final class _DisposeRequest extends _Request {
  const _DisposeRequest(super.id);
}

/// Base response type sent from Isolate → main.
sealed class _Response {
  const _Response(this.id);
  final int id;
}

final class _RunResponse extends _Response {
  const _RunResponse(super.id, this.result);
  final MontyResult result;
}

final class _ProgressResponse extends _Response {
  const _ProgressResponse(super.id, this.progress);
  final MontyProgress progress;
}

final class _SnapshotResponse extends _Response {
  const _SnapshotResponse(super.id, this.data);
  final Uint8List data;
}

final class _RestoreResponse extends _Response {
  const _RestoreResponse(super.id);
}

final class _DisposeResponse extends _Response {
  const _DisposeResponse(super.id);
}

final class _ErrorResponse extends _Response {
  const _ErrorResponse(super.id, this.message);
  final String message;
}

// =============================================================================
// Isolate entry point
// =============================================================================

Future<void> _isolateEntryPoint(_InitMessage init) async {
  final receivePort = ReceivePort();
  init.mainSendPort.send(_ReadyMessage(receivePort.sendPort));

  var monty = MontyFfi(
    bindings: NativeBindingsFfi(libraryPath: init.libraryPath),
  );

  await for (final message in receivePort) {
    if (message is! _Request) continue;

    try {
      switch (message) {
        case _RunRequest(
            :final id,
            :final code,
            :final limits,
            :final scriptName,
          ):
          final result = await monty.run(
            code,
            limits: limits,
            scriptName: scriptName,
          );
          init.mainSendPort.send(_RunResponse(id, result));

        case _StartRequest(
            :final id,
            :final code,
            :final externalFunctions,
            :final limits,
            :final scriptName,
          ):
          final progress = await monty.start(
            code,
            externalFunctions: externalFunctions,
            limits: limits,
            scriptName: scriptName,
          );
          init.mainSendPort.send(_ProgressResponse(id, progress));

        case _ResumeRequest(:final id, :final returnValue):
          final progress = await monty.resume(returnValue);
          init.mainSendPort.send(_ProgressResponse(id, progress));

        case _ResumeWithErrorRequest(:final id, :final errorMessage):
          final progress = await monty.resumeWithError(errorMessage);
          init.mainSendPort.send(_ProgressResponse(id, progress));

        case _SnapshotRequest(:final id):
          final data = await monty.snapshot();
          init.mainSendPort.send(_SnapshotResponse(id, data));

        case _RestoreRequest(:final id, :final data):
          final restored = await monty.restore(data);
          monty = restored as MontyFfi;
          init.mainSendPort.send(_RestoreResponse(id));

        case _DisposeRequest(:final id):
          await monty.dispose();
          init.mainSendPort.send(_DisposeResponse(id));
          receivePort.close();
          return;
      }
    } on MontyException catch (e) {
      init.mainSendPort.send(_ErrorResponse(message.id, e.message));
    } on Object catch (e) {
      init.mainSendPort.send(_ErrorResponse(message.id, e.toString()));
    }
  }
}

// =============================================================================
// DesktopBindingsIsolate
// =============================================================================

/// Real [DesktopBindings] implementation backed by a background Isolate.
///
/// Spawns a same-group Isolate that creates a [MontyFfi] with
/// [NativeBindingsFfi]. Communication uses sealed `_Request`/`_Response`
/// classes sent directly (no JSON encoding needed for same-group isolates).
///
/// Pass [libraryPath] to override the default native library resolution.
/// This is useful for integration tests where `DYLD_LIBRARY_PATH` may not
/// propagate to the spawned Isolate.
class DesktopBindingsIsolate extends DesktopBindings {
  /// Creates a [DesktopBindingsIsolate].
  ///
  /// If [libraryPath] is provided, it is forwarded to [NativeBindingsFfi]
  /// inside the Isolate to override the default library lookup.
  DesktopBindingsIsolate({this.libraryPath});

  /// Optional path to the native shared library.
  final String? libraryPath;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  int _nextId = 0;
  final Map<int, Completer<_Response>> _pending = {};

  @override
  Future<bool> init() async {
    _receivePort = ReceivePort();
    final completer = Completer<SendPort>();

    _receivePort!.listen((message) {
      if (message is _ReadyMessage) {
        completer.complete(message.sendPort);
        return;
      }
      if (message is _Response) {
        final pending = _pending.remove(message.id);
        pending?.complete(message);
        return;
      }
      // Isolate exit (null) or error (List<String>) — fail pending futures.
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Isolate failed to start: $message'),
        );
      }
      _failAllPending('Isolate exited unexpectedly: $message');
    });

    _isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _InitMessage(_receivePort!.sendPort, libraryPath: libraryPath),
    );

    _isolate!.addOnExitListener(
      _receivePort!.sendPort,
    );

    _isolate!.addErrorListener(_receivePort!.sendPort);

    _sendPort = await completer.future;
    return true;
  }

  Future<T> _send<T extends _Response>(_Request request) {
    if (_sendPort == null) {
      throw StateError('Isolate not initialized. Call init() first.');
    }
    final completer = Completer<_Response>();
    _pending[request.id] = completer;
    _sendPort!.send(request);

    return completer.future.then((response) {
      if (response is _ErrorResponse) {
        throw MontyException(message: response.message);
      }
      return response as T;
    });
  }

  void _failAllPending(String message) {
    final pending = Map<int, Completer<_Response>>.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(MontyException(message: message));
      }
    }
  }

  @override
  Future<DesktopRunResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    final response = await _send<_RunResponse>(
      _RunRequest(_nextId++, code, limits: limits, scriptName: scriptName),
    );
    return DesktopRunResult(result: response.result);
  }

  @override
  Future<DesktopProgressResult> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    final response = await _send<_ProgressResponse>(
      _StartRequest(
        _nextId++,
        code,
        externalFunctions: externalFunctions,
        limits: limits,
        scriptName: scriptName,
      ),
    );
    return DesktopProgressResult(progress: response.progress);
  }

  @override
  Future<DesktopProgressResult> resume(Object? returnValue) async {
    final response = await _send<_ProgressResponse>(
      _ResumeRequest(_nextId++, returnValue),
    );
    return DesktopProgressResult(progress: response.progress);
  }

  @override
  Future<DesktopProgressResult> resumeWithError(String errorMessage) async {
    final response = await _send<_ProgressResponse>(
      _ResumeWithErrorRequest(_nextId++, errorMessage),
    );
    return DesktopProgressResult(progress: response.progress);
  }

  @override
  Future<Uint8List> snapshot() async {
    final response = await _send<_SnapshotResponse>(
      _SnapshotRequest(_nextId++),
    );
    return response.data;
  }

  @override
  Future<void> restore(Uint8List data) async {
    await _send<_RestoreResponse>(_RestoreRequest(_nextId++, data));
  }

  @override
  Future<void> dispose() async {
    if (_sendPort == null) return;

    try {
      await _send<_DisposeResponse>(_DisposeRequest(_nextId++));
    } on MontyException {
      // Isolate may already be gone.
    } finally {
      _failAllPending('Isolate disposed');
      _receivePort?.close();
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _sendPort = null;
      _receivePort = null;
    }
  }
}
