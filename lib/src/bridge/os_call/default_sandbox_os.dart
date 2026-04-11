/// Platform-aware default OsProvider.
///
/// Uses conditional imports to select the right implementation:
/// - Native (dart:io): full filesystem + environment + datetime
/// - Web (dart:js_interop): datetime only, filesystem ops rejected
library;

export 'default_sandbox_os_stub.dart'
    if (dart.library.io) 'default_sandbox_os_native.dart'
    if (dart.library.js_interop) 'default_sandbox_os_web.dart';
