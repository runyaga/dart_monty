# Event Loop Coroutines

Standard Python execution is "One-Shot": you provide code, it runs to completion, and returns a result. `EventLoopPlugin` transforms this into a multi-turn, cooperative exchange, allowing Python to act as a long-running coroutine.

## The Cooperative Protocol

In an event-loop session, Python doesn't just run and exit. It uses two key functions to communicate with Dart:

1. **`el_emit(value)`**: Python pushes data to the host without stopping. This is useful for streaming progress updates, partial results, or status messages.
2. **`el_recv()`**: Python suspends execution and waits for the host to send an event. This turns Python into a stateful listener.

```python
# Python Coroutine Example
el_emit({"status": "starting"})

while True:
    # Python pauses here until Dart calls plugin.dispatch()
    event = el_recv()
    
    if event["action"] == "stop":
        break
        
    result = process(event["data"])
    el_emit({"result": result})

"Finished"
```

## The Host-Side Scheduler

On the Dart side, your application acts as the scheduler. You decide when Python should resume by dispatching events to the plugin.

```dart
final plugin = EventLoopPlugin();
final session = AgentSession(plugins: [plugin]);

// Start the coroutine (it will block at the first el_recv)
session.execute(script);

// Later, in response to a UI button click:
plugin.dispatch({"action": "process", "data": 123});
```

## Queueing and Buffering

What happens if your Dart code dispatches an event before Python is ready to receive it?

`EventLoopPlugin` maintains an internal **FIFO (First-In-First-Out) Queue**.

- If Python is already waiting (`el_recv`), the event is delivered immediately.
- If Python is busy processing or hasn't reached `el_recv` yet, the event is stored in the queue and delivered the moment Python calls `el_recv()`.

## Reactive UI Integration

The `EventLoopPlugin` provides reactive signals that allow your UI to respond to the coroutine's state automatically.

- **`channelStateSignal`**: Tells you if Python is `idle`, `executing`, or `waiting`. You can use this to show/hide an input field or a "Bot is thinking" spinner.
- **`lastEmittedSignal`**: Emits the most recent value sent via `el_emit()`. Perfect for driving a real-time log or progress bar.

```dart
effect(() {
  final state = plugin.channelStateSignal.value;
  if (state is BridgeChannelWaiting) {
    showInputPrompt();
  }
});
```

## Error Handling and Cleanup

If the Python script encounters an error while it is suspended (`waiting`), or if the session is disposed, the `EventLoopPlugin` ensures that the pending `el_recv()` is cancelled and resources are cleaned up properly. This prevents "Orphaned" execution tasks from leaking memory or CPU time.
