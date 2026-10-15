/// What the acceptance suite needs to know about the platform it runs on.
library;

export '_platform_web.dart' if (dart.library.io) '_platform_io.dart';
