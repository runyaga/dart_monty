import 'dart:async';

/// Runs [body] and, when it throws or fails with an error [test] accepts,
/// answers with [onError].
///
/// A synchronous throw is handled synchronously and a synchronous answer
/// stays synchronous: core honours an `OsCallNotHandledException` only as a
/// synchronous throw, so a decline must not pass through an `async` frame.
/// Only a `Future` [body] returns is handled asynchronously.
FutureOr<T> recoverFrom<T>(
  FutureOr<T> Function() body, {
  required bool Function(Object error) test,
  required FutureOr<T> Function(Object error, StackTrace stack) onError,
}) {
  final FutureOr<T> result;
  try {
    result = body();
  } on Object catch (e, st) {
    if (!test(e)) rethrow;

    return onError(e, st);
  }

  return result is Future<T> ? _recoverAsync(result, test, onError) : result;
}

Future<T> _recoverAsync<T>(
  Future<T> pending,
  bool Function(Object error) test,
  FutureOr<T> Function(Object error, StackTrace stack) onError,
) async {
  try {
    return await pending;
  } on Object catch (e, st) {
    if (!test(e)) rethrow;

    return onError(e, st);
  }
}

/// Applies [next] to [value], synchronously when [value] is not a `Future`.
FutureOr<R> thenOrNow<T, R>(FutureOr<T> value, FutureOr<R> Function(T) next) =>
    value is Future<T> ? _thenAsync(value, next) : next(value);

Future<R> _thenAsync<T, R>(
  Future<T> pending,
  FutureOr<R> Function(T) next,
) async => next(await pending);
