import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';

/// One `feedRun` a [RecordingSession] saw.
final class RecordedFeed {
  /// A feed of [code] with these arguments.
  const RecordedFeed(this.code, this.inputs, this.externalLookup, this.os);

  /// The code fed.
  final String code;

  /// The feed's `inputs`.
  final Map<String, MontyValue>? inputs;

  /// The feed's `externalLookup`.
  final Map<String, MontyValue>? externalLookup;

  /// The feed's `os` handler.
  final OsHandler? os;
}

/// A session that records each `feedRun`'s arguments and whether it was
/// closed, and passes every call to [inner].
final class RecordingSession implements MontySession {
  /// Records the calls made on [inner].
  RecordingSession(this.inner);

  /// The session every call goes to.
  final MontySession inner;

  /// The feeds, in order.
  final List<RecordedFeed> feeds = [];

  /// Whether [close] was called.
  bool closed = false;

  /// When set, a failing `feedRun` reports its error only once this
  /// completes.
  Future<void>? holdFailure;

  /// The error raised by the most recent failing feed, before wrapping by dm.
  Object? feedError;

  @override
  int? get workerPid => inner.workerPid;

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    FutureOr<void> Function(String stream, String text)? printCallback,
    String? cwd,
    OsHandler? os,
    List<MountDir>? mount,
    bool skipTypeCheck = false,
  }) {
    feeds.add(RecordedFeed(code, inputs, externalLookup, os));

    final fed = inner.feedRun(
      code,
      inputs: inputs,
      externalLookup: externalLookup,
      printCallback: printCallback,
      cwd: cwd,
      os: os,
      mount: mount,
      skipTypeCheck: skipTypeCheck,
    );
    final hold = holdFailure;
    return fed.catchError((Object e, StackTrace st) async {
      feedError = e;
      if (hold != null) await hold;
      Error.throwWithStackTrace(e, st);
    });
  }

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    FutureOr<void> Function(String stream, String text)? printCallback,
    String? cwd,
    OsHandler? os,
    List<MountDir>? mount,
    bool skipTypeCheck = false,
  }) => inner.feedStart(
    code,
    inputs: inputs,
    externalLookup: externalLookup,
    printCallback: printCallback,
    cwd: cwd,
    os: os,
    mount: mount,
    skipTypeCheck: skipTypeCheck,
  );

  @override
  Future<void> loadSession(Uint8List state) => inner.loadSession(state);

  @override
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    Map<String, MontyValue>? externalLookup,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
    List<MountDir>? mount,
  }) => inner.loadSnapshot(
    state,
    externalLookup: externalLookup,
    printCallback: printCallback,
    os: os,
    mount: mount,
  );

  @override
  Future<void> installDependencies(List<String> requirements) =>
      inner.installDependencies(requirements);

  @override
  Future<Uint8List> dump() => inner.dump();

  @override
  Future<void> close() {
    closed = true;

    return inner.close();
  }
}
