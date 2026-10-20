import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';

/// A session whose feeds throw [error], which is not a [MontyError].
final class ThrowingSession implements MontySession {
  /// A session whose feeds throw [error].
  const ThrowingSession(this.error);

  /// What every feed throws.
  final Object error;

  @override
  int? get workerPid => null;

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
  }) async {
    // ignore: only_throw_errors – the test needs a non-Exception throw.
    throw error;
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
  }) async {
    // ignore: only_throw_errors – the test needs a non-Exception throw.
    throw error;
  }

  @override
  Future<void> loadSession(Uint8List state) async {
    // The fake has no session state to restore.
  }

  @override
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    Map<String, MontyValue>? externalLookup,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
    List<MountDir>? mount,
  }) async => throw UnsupportedError('loadSnapshot');

  @override
  Future<void> installDependencies(List<String> requirements) async {
    // The fake has no dependencies to install.
  }

  @override
  Future<Uint8List> dump() async => Uint8List(0);

  @override
  Future<void> close() async {
    // The fake holds no resources to release.
  }
}

/// A session whose feed makes one OS call, [name] with [args], through the
/// `os` handler it is given, records what that handler returned in
/// [returned], awaits it, and completes with [MontyNone].
final class OsProbeSession extends ThrowingSession {
  /// A session whose feed calls the OS function [name] once.
  OsProbeSession(this.name, [this.args = const []])
    : super(StateError('feedStart is not scripted'));

  /// The OS function the feed calls.
  final String name;

  /// Its positional arguments.
  final List<MontyValue> args;

  /// What the `os` handler returned, before it was awaited.
  FutureOr<MontyValue>? returned;

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
  }) async {
    final answer = os!(name, args, const {});
    returned = answer;
    await answer;

    return const MontyNone();
  }
}
