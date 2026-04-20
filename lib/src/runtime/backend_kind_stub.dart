import 'package:dart_monty/src/runtime/backend_kind.dart';

/// Stub fallback for [currentBackendKind] — throws on any compile target
/// without `dart.library.ffi` or `dart.library.js_interop`.
MontyBackendKind get currentBackendKind => throw UnsupportedError(
  'No Monty backend available for this compile target. '
  'Expected dart.library.ffi or dart.library.js_interop.',
);
