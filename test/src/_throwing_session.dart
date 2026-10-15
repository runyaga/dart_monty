import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';

/// A session whose feeds throw [error], which is not a [MontyError].
final class ThrowingSession implements MontySession {
  /// A session whose feeds throw [error].
  ThrowingSession(this.error);

  /// What every feed throws.
  final Object error;

  @override
  int? get workerPid => null;

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, Object>? inputs,
    Map<
      String,
      FutureOr<MontyValue> Function(List<MontyValue>, Map<String, MontyValue>)
    >?
    externals,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) async {
    // ignore: only_throw_errors – the test needs a non-Exception throw.
    throw error;
  }

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, Object>? inputs,
    Map<
      String,
      FutureOr<MontyValue> Function(List<MontyValue>, Map<String, MontyValue>)
    >?
    externals,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) async {
    // ignore: only_throw_errors – the test needs a non-Exception throw.
    throw error;
  }

  @override
  Future<void> loadSession(Uint8List state) async {}

  @override
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    Map<
      String,
      FutureOr<MontyValue> Function(List<MontyValue>, Map<String, MontyValue>)
    >?
    externals,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
  }) async => throw UnsupportedError('loadSnapshot');

  @override
  Future<Uint8List> dump() async => Uint8List(0);

  @override
  Future<void> close() async {}
}
