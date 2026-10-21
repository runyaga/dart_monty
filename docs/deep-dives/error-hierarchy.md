# Failure propagation

Core reports parser, runtime, type-check, and worker failures as sealed
`MontyError` values. Look in core's public error source for the current
subclasses and their fields.

[`_endsSession`](https://github.com/runyaga/dart_monty/blob/main/lib/src/runtime/runtime.dart)
selects terminal errors.

`MontyBridge` reports a failed feed as `BridgeRunError`. The event stream and
the execution result provide different recovery paths.

Code that needs typed recovery should use [ExecutionHandle](https://github.com/runyaga/dart_monty/blob/main/lib/src/runtime/execution_handle.dart).
Code that renders an event stream should use [BridgeRunError](https://github.com/runyaga/dart_monty/blob/main/lib/src/bridge/event.dart).

Host and OS handlers define their failure behavior through
[ExternalException](https://github.com/runyaga/dart_monty/blob/main/lib/src/host/dispatch.dart)
and
[OsCallNotHandledException](https://github.com/runyaga/dart_monty/blob/main/lib/src/os_call/os_handlers.dart).

See [extractBridgeResult](https://github.com/runyaga/dart_monty/blob/main/lib/src/runtime/runtime_state.dart).
