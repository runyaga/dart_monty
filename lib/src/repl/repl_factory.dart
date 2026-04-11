export 'repl_factory_stub.dart'
    if (dart.library.ffi) 'repl_factory_native.dart'
    if (dart.library.js_interop) 'repl_factory_web.dart';
