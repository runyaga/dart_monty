# D2 facade migration

Import `package:dart_monty/dart_monty.dart` for runtime and extension APIs.
The former bridge entry point has been removed. Core re-exports are limited
to `Monty`, `MontySession`, `MontyValue`, `MontyNone`, `MontyError`,
`ResourceLimits`, `OsHandler`, `OsCallNotHandledException` and `ExternalException`.
Import other core types from `package:dart_monty_core/dart_monty_core.dart`.

The message bus moved to the extras package (E19); its delivery is separate.
No compatibility alias or extras dependency is added to dart_monty.

Filesystem handlers and child state names remain exported during D2; their
removal belongs to D4a and D5. Host function signatures are unchanged in D2.
