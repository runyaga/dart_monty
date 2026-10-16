/// Where the integration tests find core's worker: the native executable on
/// the VM, core's committed Web Worker assets in a browser.
library;

export '_worker_web.dart' if (dart.library.io) '_worker_io.dart';
