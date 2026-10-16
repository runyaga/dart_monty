/// Platform-aware default `OsHandler`.
///
/// Uses conditional imports to select the right implementation:
/// - Native (`dart:io`): `LocalFileSystem` + host environment
/// - Web (`dart:js_interop`): in-memory VFS (no env access)
/// - Otherwise: declines every call
library;

export 'default_os_handler_stub.dart'
    if (dart.library.io) 'default_os_handler_native.dart'
    if (dart.library.js_interop) 'default_os_handler_web.dart';
