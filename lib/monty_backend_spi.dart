/// Backward-compatibility re-export for test files that previously imported
/// the platform SPI from the old multi-package layout.
///
/// All types are now in dart_monty_core.
library;

export 'package:dart_monty_core/dart_monty_core.dart' hide OsCallException;
