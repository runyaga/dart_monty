import 'package:dart_monty/src/runtime/backend_kind.dart';

/// Rejects compile targets without FFI or JavaScript interop.
MontyBackendKind get currentBackendKind => throw UnsupportedError(
  'No Monty backend available for this compile target. '
  'Expected dart.library.ffi or dart.library.js_interop.',
);
