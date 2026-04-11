import 'package:dart_monty/dart_monty.dart';

/// Interface for handling OS-level calls from sandboxed Python code.
///
/// OS calls are triggered implicitly when Python accesses standard library
/// modules like `pathlib`, `os`, or `datetime`. The interpreter pauses and
/// yields a [MontyOsCall] describing the operation. The bridge invokes
/// [handle] and resumes Python with the returned value.
///
/// Implementations should throw `OsCallException` (or subclasses) for
/// domain errors (file not found, permission denied, etc.). The bridge
/// translates these into the corresponding Python exception types.
abstract class OsCallHandler {
  /// Handles the OS call and returns the result to resume Python.
  ///
  /// Throw an `OsCallException` to resume Python with a typed error.
  Future<Object?> handle(MontyOsCall call);

  /// Lifecycle hook called when the bridge is disposed.
  ///
  /// Override to release resources (temp directories, open files, etc.).
  Future<void> dispose() async {}
}
