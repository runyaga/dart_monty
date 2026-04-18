/// Platform-aware default `OsCallHandler`.
///
/// Uses conditional imports to select the right implementation:
/// - Native (`dart:io`): `LocalFileSystem` + host environment + datetime
/// - Web (`dart:js_interop`): in-memory VFS + datetime (no env access)
library;

export 'default_os_handler_stub.dart'
    if (dart.library.io) 'default_os_handler_native.dart'
    if (dart.library.js_interop) 'default_os_handler_web.dart';
