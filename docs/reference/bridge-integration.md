# Browser bridge integration

Browser execution belongs to `dart_monty_core`. A core pool communicates with
a Web Worker that owns the WASM interpreter. `dart_monty` drives the same
public session feed on native and web targets, so its bridge does not depend on
JavaScript interop or worker message shapes.

When Python calls a Dart host function, the session feed reports a suspension.
`MontyBridge` validates the arguments, awaits the handler, and resumes the
feed with a value or an external error. Repeated suspensions stay within the
same execution until the feed completes or fails.

The Web Worker isolates interpreter work from the browser main thread. Worker
assets must be served from core's package asset location, or the pool must
receive an explicit worker location. The page must also be cross-origin
isolated because the worker transport uses `SharedArrayBuffer`.

The current transport and asset implementation is in the `dart_monty_core`
package. Its public pool and session declarations define the worker lifecycle.
[SessionBridge](https://github.com/runyaga/dart_monty/blob/main/lib/src/bridge/session_bridge.dart)
defines host-call dispatch and event ordering.
