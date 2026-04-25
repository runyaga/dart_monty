# Bridge Middleware

Bridge middleware provides a powerful mechanism for intercepting every tool call, allowing for cross-cutting concerns like logging, rate limiting, and access control without modifying individual extension handlers.

**Prerequisites:** Read the [Intermediate guide](host-functions-intermediate.md) (extensions) and the [Advanced guide](host-functions-advanced.md) (sandboxing).

## The Middleware Pattern

Middleware is implemented as a chain of handlers that wrap the core tool dispatch logic. Each middleware can inspect a request, modify it, short-circuit it, or pass it down the chain. This is identical to the onion-style middleware in frameworks like Express or Shelf.

```text
Python tool call
    |
    v
PlatformBridge._dispatchToolCall()
    |
    v  +--------------------------------------+
       |  Middleware Chain (onion model)      |
       |                                      |
       |  +- Middleware 1 (first registered)  |
       |  |   +- Middleware 2                 |
       |  |   |   +- Extension Handler        |
       |  |   |   +---------------------------+
       |  |   +-------------------------------+
       |  +-----------------------------------+
       +--------------------------------------+
    |
    v
Result -> Python
```

## Writing Middleware

Implement the `BridgeMiddleware` abstract class and its `handle` method:

```dart
abstract class BridgeMiddleware {
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  );
}
```
- **`name`**: The name of the host function being called.
- **`args`**: The validated arguments for the function.
- **`role`**: The `CallRole` indicating if this is an infrastructure or tool call.
- **`next`**: A function to call the next middleware in the chain.

### Example: Telemetry Middleware
This middleware logs the duration of every tool call.

```dart
class TelemetryMiddleware extends BridgeMiddleware {
  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    final sw = Stopwatch()..start();
    try {
      return await next(name, args);
    } finally {
      sw.stop();
      print('Call to "$name" took ${sw.elapsedMilliseconds}ms');
    }
  }
}
```

### Example: Access Control Middleware
This middleware denies access to certain functions based on the `CallRole`.

```dart
class AccessControlMiddleware extends BridgeMiddleware {
  final Set<String> _deniedFunctions;
  AccessControlMiddleware(this._deniedFunctions);

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    // Only enforce policy on agent tool calls, not infrastructure calls
    if (role is ToolCall && _deniedFunctions.contains(name)) {
      throw StateError('Access denied: function "$name" is not permitted.');
    }
    return next(name, args);
  }
}
```

## Registering Middleware

Middleware must be registered on the `PlatformBridge` **before** extensions are attached. The order of registration matters: the first middleware registered is the outermost in the chain.

```dart
// 1. Create the bridge
final bridge = PlatformBridge(platform: MontyFfi());

// 2. Register middleware (outermost first)
bridge.use(TelemetryMiddleware());
bridge.use(AccessControlMiddleware({'file_delete'}));

// 3. Attach extensions
final coordinator = ExtensionCoordinator()
  ..register(FileExtension())
  ..register(WebExtension());
await coordinator.attachTo(bridge);

// Now the bridge is ready to execute
final runtime = MontyRuntime(bridge: bridge, coordinator: coordinator);
```
In this example, the `TelemetryMiddleware` will wrap the `AccessControlMiddleware`, so it will time the call including any access control logic.
