import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

// =============================================================================
// Message types (private sealed classes)
// =============================================================================

/// Initial configuration sent from main -> Isolate at spawn time.
final class _InitMessage {
  const _InitMessage(this.mainSendPort);
  final SendPort mainSendPort;
}

/// Message sent from the Isolate once it's ready.
final class _ReadyMessage {
  const _ReadyMessage(this.sendPort);
  final SendPort sendPort;
}

/// Base request type sent from main -> Isolate.
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

final class _ResumeAsFutureRequest extends _Request {
  const _ResumeAsFutureRequest(super.id);
}

final class _ResolveFuturesRequest extends _Request {
  const _ResolveFuturesRequest(super.id, this.results, {this.errors});
  final Map<int, Object?> results;
  final Map<int, String>? errors;
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

/// Base response type sent from Isolate -> main.
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
  const _ErrorResponse(super.id, this.exception);
  final MontyException exception;
}

final class _GenericErrorResponse extends _Response {
  const _GenericErrorResponse(super.id, this.message);
  final String message;
}

/// Carries a sealed [MontyError] subtype across the isolate boundary.
final class _MontyErrorResponse extends _Response {
  const _MontyErrorResponse(super.id, this.error);
  final MontyError error;
}

/// Notification sent from the worker isolate to the supervisor with the
/// monotonic handle ID, immediately after create() and before blocking
/// run()/start(). This prevents the handleId-routing deadlock where an
/// infinite loop would never send a response containing the handleId.
final class _HandleIdNotification {
  const _HandleIdNotification(this.handleId);
  final int handleId;
}

// =============================================================================
// Isolate entry point
// =============================================================================

// coverage:ignore-start — isolate entry point; only testable via integration.
/// Sync wrapper for [Isolate.spawn] which expects `void Function(T)`.
void _isolateEntryPoint(_InitMessage init) {
  unawaited(_isolateMain(init));
}

Future<void> _isolateMain(_InitMessage init) async {
  final receivePort = ReceivePort();
  init.mainSendPort.send(_ReadyMessage(receivePort.sendPort));

  final nativeBindings = NativeBindingsFfi();
  final ffiCoreBindings = FfiCoreBindings(
    bindings: nativeBindings,
    onHandleCreated: (handleId) {
      init.mainSendPort.send(_HandleIdNotification(handleId));
    },
  );
  var monty = MontyFfi.withCore(
    coreBindings: ffiCoreBindings,
    nativeBindings: nativeBindings,
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

        case _ResumeAsFutureRequest(:final id):
          final progress = await monty.resumeAsFuture();
          init.mainSendPort.send(_ProgressResponse(id, progress));

        case _ResolveFuturesRequest(:final id, :final results, :final errors):
          final progress = await monty.resolveFutures(results, errors: errors);
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
    } on MontyError catch (e) {
      init.mainSendPort.send(_MontyErrorResponse(message.id, e));
    } on MontyException catch (e) {
      init.mainSendPort.send(_ErrorResponse(message.id, e));
    } on Object catch (e) {
      init.mainSendPort.send(_GenericErrorResponse(message.id, e.toString()));
    }
  }
}
// coverage:ignore-end

// =============================================================================
// NativeIsolateBindingsImpl
// =============================================================================

/// Real [NativeIsolateBindings] implementation backed by a background Isolate.
///
/// Spawns a same-group Isolate that creates a [MontyFfi] with
/// [NativeBindingsFfi]. Communication uses sealed `_Request`/`_Response`
/// classes sent directly (no JSON encoding needed for same-group isolates).
///
/// The native library is resolved automatically by the Dart native assets
/// system via `@Native` annotations — no manual path is needed.
class NativeIsolateBindingsImpl extends NativeIsolateBindings {
  /// Creates a [NativeIsolateBindingsImpl].
  ///
  /// If [initTimeout] is provided, the isolate must send [_ReadyMessage]
  /// within this duration or [init] throws a [StateError].
  NativeIsolateBindingsImpl({this.initTimeout});

  /// Timeout for the worker isolate to send [_ReadyMessage] during [init].
  /// Defaults to 30 seconds if not provided.
  final Duration? initTimeout;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  int _nextId = 0;
  final Map<int, Completer<_Response>> _pending = {};

  /// Monotonic handle ID received from the worker isolate via
  /// [_HandleIdNotification]. Available after the first run/start request.
  int? _handleId;

  /// The handle ID for cross-isolate cancel, or `null` if not yet available.
  int? get handleId => _handleId;

  Completer<void>? _exitCompleter;

  /// Number of worker isolates that failed to exit within the terminate
  /// timeout and were force-killed.
  static int _zombieCount = 0;

  /// Emit a diagnostic warning once zombie count reaches this threshold.
  static const int _zombieWarningThreshold = 3;

  /// The number of zombie worker isolates observed so far.
  static int get zombieCount => _zombieCount;

  @override
  Future<bool> init() async {
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    _exitCompleter = Completer<void>();
    final completer = Completer<SendPort>();

    receivePort.listen((message) {
      if (message is _ReadyMessage) {
        completer.complete(message.sendPort);

        return;
      }
      if (message is _HandleIdNotification) {
        _handleId = message.handleId;

        return;
      }
      if (message is _Response) {
        final pending = _pending.remove(message.id);
        pending?.complete(message);

        return;
      }
      // Isolate exit (null from addOnExitListener).
      if (message == null) {
        if (_exitCompleter != null && !_exitCompleter!.isCompleted) {
          _exitCompleter!.complete();
        }
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Isolate exited before sending _ReadyMessage'),
          );
        }
        _failAllPending('Isolate exited');

        return;
      }
      // Isolate error (List from addErrorListener) — fail pending futures.
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Isolate failed to start: $message'),
        );
      }
      _failAllPending('Isolate error: $message');
    });

    final isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _InitMessage(receivePort.sendPort),
    );
    _isolate = isolate;

    isolate
      ..addOnExitListener(receivePort.sendPort)
      ..addErrorListener(receivePort.sendPort);

    _sendPort = await completer.future.timeout(
      initTimeout ?? const Duration(seconds: 30),
      onTimeout: () => throw StateError(
        'Worker isolate failed to initialize within timeout. '
        'Possible silent crash before _ReadyMessage was sent.',
      ),
    );

    // Initialize FFI on the main isolate so that MontyCancelToken and
    // direct NativeBindingsFfi access work cross-isolate.  Dart static
    // state is per-isolate, so the worker's NativeBindingsFfi registration
    // does not propagate here.
    NativeBindingsFfi.ensureInitialized();

    return true;
  }

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    final response = await _send<_RunResponse>(
      _RunRequest(_nextId++, code, limits: limits, scriptName: scriptName),
    );

    return response.result;
  }

  @override
  Future<MontyProgress> start(
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

    return response.progress;
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    final response = await _send<_ProgressResponse>(
      _ResumeRequest(_nextId++, returnValue),
    );

    return response.progress;
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    final response = await _send<_ProgressResponse>(
      _ResumeWithErrorRequest(_nextId++, errorMessage),
    );

    return response.progress;
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    final response = await _send<_ProgressResponse>(
      _ResumeAsFutureRequest(_nextId++),
    );

    return response.progress;
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
    final response = await _send<_ProgressResponse>(
      _ResolveFuturesRequest(_nextId++, results, errors: errors),
    );

    return response.progress;
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

    // Cancel first so a stuck FFI call (e.g. infinite loop) unblocks before
    // we send the dispose command.  Without this, dispose() hangs forever
    // waiting for a port reply that the blocked isolate can never send.
    // See: https://github.com/runyaga/dart_monty/issues/113
    // coverage:ignore-start — exercised by integration tests (T2-2)
    await cancel();
    // coverage:ignore-end

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
      _handleId = null;
    }
  }

  /// Cancel the current execution via `cancelById` (cross-isolate safe).
  ///
  /// No-op if the handle ID has not been received yet.
  Future<void> cancel() async {
    final hid = _handleId;
    if (hid != null) {
      NativeBindingsFfi.ensureInitialized();
      NativeBindingsFfi.instanceOrNull?.cancelById(hid);
    }
  }

  /// Cancel and force-kill the worker isolate.
  ///
  /// Waits up to 5 seconds for the isolate to exit gracefully after cancel.
  /// If the isolate does not exit in time, it is killed and counted as a
  /// zombie (the Rust handle may leak because `freeById` is skipped to
  /// avoid use-after-free on the Rust handle).
  Future<void> terminate() async {
    await cancel();
    // Ask the worker to exit cleanly.  After cancel halts execution the
    // worker is idle in its event loop; sending dispose lets it shut down
    // gracefully so we avoid the zombie/skip-freeById path.
    _sendPort?.send(_DisposeRequest(_nextId++));
    if (_exitCompleter != null && !_exitCompleter!.isCompleted) {
      final exited = await _exitCompleter!.future
          .timeout(const Duration(seconds: 5))
          .then((_) => true)
          .onError((_, _) => false);
      if (!exited) {
        _zombieCount++;
        if (_zombieCount >= _zombieWarningThreshold) {
          developer.log(
            'dart_monty_ffi: $_zombieCount zombie isolate(s) detected. '
            'Rust MontyHandle(s) leaked. '
            'Consider investigating long-running or stuck executions.',
            name: 'dart_monty_ffi',
            level: 900, // WARNING
          );
        }
        _cleanupAfterCrashDisposal(skipFreeById: true);

        return;
      }
    }
    _cleanupAfterCrashDisposal();
  }

  /// Crash-only cleanup: kill isolate, close port, free Rust handle.
  ///
  /// If [skipFreeById] is `true`, the Rust handle is NOT freed via
  /// `freeById` — used when the isolate did not exit cleanly and the
  /// handle may already be invalid (prevents use-after-free).
  void _cleanupAfterCrashDisposal({bool skipFreeById = false}) {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _receivePort = null;
    _isolate = null;
    _failAllPending('Isolate crashed or was force-killed');
    if (_handleId != null) {
      if (!skipFreeById) {
        NativeBindingsFfi.instanceOrNull?.freeById(_handleId!);
      }
      _handleId = null;
    }
    _sendPort = null;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<T> _send<T extends _Response>(_Request request) {
    if (_sendPort == null) {
      throw StateError('Isolate not initialized. Call init() first.');
    }
    final completer = Completer<_Response>();
    _pending[request.id] = completer;
    _sendPort?.send(request);

    return completer.future.then((response) {
      if (response is _MontyErrorResponse) {
        throw response.error;
      }
      if (response is _ErrorResponse) {
        throw response.exception;
      }
      if (response is _GenericErrorResponse) {
        throw StateError(response.message);
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
}
