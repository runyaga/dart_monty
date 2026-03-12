export 'monty_factory_stub.dart'
    if (dart.library.ffi) 'monty_factory_native.dart'
    if (dart.library.js_interop) 'monty_factory_web.dart';
