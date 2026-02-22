/// macOS and Linux desktop implementation of dart_monty.
library;

import 'package:dart_monty_desktop/src/desktop_bindings_isolate.dart';
import 'package:dart_monty_desktop/src/monty_desktop.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

export 'src/desktop_bindings.dart';
export 'src/desktop_bindings_isolate.dart';
export 'src/monty_desktop.dart';

/// macOS and Linux desktop implementation of dart_monty.
class DartMontyDesktop {
  /// Registers this plugin as the platform implementation.
  static void registerWith() {
    MontyPlatform.instance = MontyDesktop(
      bindings: DesktopBindingsIsolate(),
    );
  }
}
