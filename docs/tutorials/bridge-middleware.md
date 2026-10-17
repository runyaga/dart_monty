# Bridge Middleware

Middleware is not a public consumer API. Use `MontyBridge.execute` and its
`BridgeEvent` stream to observe bridge activity.

**Prerequisites:** Read the [Intermediate guide](host-functions-intermediate.md).

## Bridge events

`MontyBridge` runs code on a `MontySession`. Its `execute` method returns a
stream containing run, host-function, and OS-call events. The stream ends
normally after `BridgeRunFinished` or `BridgeRunError`.

```dart
final session = await monty.checkout();
final bridge = MontyBridge(session: session);

await for (final event in bridge.execute('2 + 2')) {
  switch (event) {
    case BridgeRunFinished(:final montyValue):
      print(montyValue?.dartValue);
    case BridgeRunError(:final message):
      print(message);
    default:
      break;
  }
}

bridge.dispose();
await session.close();
```

`BridgeFunctionCallStart`, `BridgeFunctionCallArgs`, `BridgeFunctionEmit`,
`BridgeFunctionCallResult`, and `BridgeFunctionCallEnd` describe a host
function call. `BridgeOsCallStart` and `BridgeOsCallResult` describe host OS
calls. `BridgeChildEvent` contains an event emitted by a sandbox child.
