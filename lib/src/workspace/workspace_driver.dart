part of 'workspace.dart';

typedef _RunOptions = ({
  Map<String, MontyValue>? inputs,
  Map<String, MontyValue>? externalLookup,
  FutureOr<void> Function(String, String)? printCallback,
  OsHandler? os,
  String? cwd,
});

/// Internal execution selection; the memory path remains core's feedRun.
extension WorkspaceDriver on Workspace {
  /// Selects the private driver while preserving core's feed call shape.
  Future<MontyValue> Function(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    FutureOr<void> Function(String, String)? printCallback,
    String? cwd,
    OsHandler? os,
  })
  driver(MontySession session) =>
      (code, {inputs, externalLookup, printCallback, os, cwd = '/work'}) =>
          _run(session, code, (
            inputs: inputs,
            externalLookup: externalLookup,
            printCallback: printCallback,
            os: os,
            cwd: cwd,
          ));

  Future<MontyValue> _run(
    MontySession session,
    String code,
    _RunOptions options,
  ) async {
    if (_freeing || _leased || _execution != null) {
      throw StateError('Workspace is unavailable');
    }
    final disk = _disk;
    if (disk == null) {
      return session.feedRun(
        code,
        inputs: options.inputs,
        externalLookup: options.externalLookup,
        printCallback: options.printCallback,
        cwd: options.cwd,
        os: compose(options.os ?? _decline),
      );
    }
    _execution = session;
    _executionDone = Completer<void>();
    MountDir? mount;
    try {
      mount = disk.open();
      final snapshot = await session.feedStart(
        code,
        inputs: options.inputs,
        externalLookup: options.externalLookup,
        printCallback: options.printCallback,
        cwd: options.cwd,
        mount: [mount],
        os: _diskHandler(options.os),
      );

      return await _drive(snapshot, disk);
    } finally {
      mount?.close();
      _execution = null;
      _executionDone?.complete();
      _executionDone = null;
    }
  }

  OsHandler _diskHandler(OsHandler? fallback) {
    // OSAccess's default is ten seconds. Core charges each surfaced sleep;
    // this handler supplies only the local wait absent from manual driving.
    final sleeps = OSAccess();

    return compose((name, args, kwargs) {
      if (name == 'system.sleep' || name == 'system.async_sleep') {
        return sleeps.call(name, args, kwargs);
      }

      return (fallback ?? _decline)(name, args, kwargs);
    });
  }

  Future<MontyValue> _drive(MontySnapshot snapshot, DiskBacking disk) async {
    var current = snapshot;
    while (true) {
      switch (current) {
        case MontyComplete(:final output):
          return output;
        case final FunctionSnapshot call:
          current = await _resumeDisk(call, disk);
        case final FutureSnapshot pending:
          current = await pending.resumeAuto();
        case final NameLookupSnapshot lookup:
          current = await lookup.resumeAuto();
      }
    }
  }

  Future<MontyValue> _persistentCall(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    if (_freeing && !_leased) {
      return Future.error(StateError('Workspace is disposed'));
    }
    final previous = _transferDone;
    final done = Completer<void>();
    _transferDone = done.future;

    return (() async {
      await previous;
      try {
        final disk = _disk ?? (throw StateError('Workspace is disposed'));
        final path = _operationPath(args.firstOrNull);
        if (!_inside(path)) throw const OsCallNotHandledException();
        disk.validate(path);
        if (!_mutates(name, args)) return call(name, args, kwargs);
        final oldAccess = _access;
        final oldWrites = _writeBytes;
        final oldMemory = _memoryUsage;
        call(name, args, kwargs);
        try {
          return await _dispatchDisk(disk, name, args, kwargs);
        } on Object {
          _access = oldAccess;
          _writeBytes = oldWrites;
          _memoryUsage = oldMemory;
          rethrow;
        }
      } finally {
        done.complete();
      }
    })();
  }

  Future<MontySnapshot> _resumeDisk(
    FunctionSnapshot snapshot,
    DiskBacking disk,
  ) async {
    if (!snapshot.isOsFunction || !_filesystem(snapshot.functionName)) {
      return snapshot.resumeAuto();
    }
    final previousMemory = _memoryUsage;
    final previousWrites = _writeBytes;
    final int payload;
    try {
      final accepted = await _preflightDisk(snapshot, disk);
      if (accepted == null) return await snapshot.resumeNotHandled();
      payload = accepted;
    } on ExternalException catch (error) {
      return snapshot.resume(error);
    }
    try {
      if (payload > 0) {
        final result = await _writeDisk(snapshot, disk, previousWrites);

        return await snapshot.resume(result);
      }

      return await snapshot.resumeAuto();
    } finally {
      // A native failure may differ from the candidate (for example rename
      // replacing a directory). Reconcile actual retained content on either
      // outcome; never claim rollback of an upstream operation.
      await _reconcile(disk, previousMemory + payload);
    }
  }

  Future<int?> _preflightDisk(
    FunctionSnapshot snapshot,
    DiskBacking disk,
  ) async {
    final name = snapshot.functionName;
    final args = snapshot.args;
    final path = _operationPath(args.firstOrNull);
    final target = name == 'Path.rename'
        ? _operationPath(args.elementAtOrNull(1))
        : null;
    if (!_inside(path) || (target != null && !_inside(target))) return null;
    disk.validate(path);
    if (target != null) disk.validate(target);
    if (!_mutates(name, args)) return 0;
    // Reuse D4a's transactional preflight and lifetime counters. The
    // candidate is private; native dispatch follows policy acceptance.
    await disk.snapshot(
      maxBytes: _memoryUsage,
      maxEntries: _memoryUsage ~/ 64 + 1,
      maxDepth: 4096,
    );
    call(name, args, snapshot.kwargs);

    return _payload(name, args);
  }

  Future<MontyValue> _dispatchDisk(
    DiskBacking disk,
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) async {
    final pool = await (_transferPool ??= disk.startTransferPool());
    final mount = disk.open();
    try {
      return await PersistentTransfer(pool, [mount]).call(name, args, kwargs);
    } finally {
      mount.close();
    }
  }

  Future<ExternalResult> _writeDisk(
    FunctionSnapshot snapshot,
    DiskBacking disk,
    int previousWrites,
  ) async {
    // Observe the operation's outcome before resuming Python: resumeAuto
    // also runs subsequent code, which can either catch or raise an error.
    try {
      return ExternalReturnValue(
        await _dispatchDisk(
          disk,
          snapshot.functionName,
          snapshot.args,
          snapshot.kwargs,
        ),
      );
    } on MontyRuntimeError catch (error) {
      _writeBytes = previousWrites;

      return ExternalException(
        error.exception.excType,
        error.exception.message,
      );
    } on Object {
      _writeBytes = previousWrites;
      rethrow;
    }
  }

  Future<void> _reconcile(DiskBacking disk, int maximum) async {
    final entries = await disk.snapshot(
      maxBytes: maximum,
      maxEntries: maximum ~/ 64 + 4096,
      maxDepth: 4096,
    );
    _access = _fromEntries(entries);
    _memoryUsage = _size(entries);
  }
}

MontyValue _decline(
  String name,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) => throw const OsCallNotHandledException();

/// Attempts every cleanup independently, preserving the first failure.
Future<void> cleanupWorkspace(
  List<FutureOr<void> Function()> operations,
) async {
  Object? first;
  StackTrace? trace;
  for (final operation in operations) {
    try {
      await operation();
    } on Object catch (error, stack) {
      first ??= error;
      trace ??= stack;
    }
  }
  if (first != null) {
    Error.throwWithStackTrace(first, trace ?? StackTrace.current);
  }
}
