/// Platform-aware default OsCallHandler.
///
/// Uses conditional imports to select the right implementation:
/// - Native (dart:io): full filesystem + environment + datetime
/// - Web (dart:js_interop): datetime only, filesystem ops rejected
library;

export 'default_os_call_handler_stub.dart'
    if (dart.library.io) 'default_os_call_handler_native.dart'
    if (dart.library.js_interop) 'default_os_call_handler_web.dart';
