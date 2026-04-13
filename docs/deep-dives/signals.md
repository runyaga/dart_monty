# Reactive state

## Why signals?

In complex agentic workloads, the UI often needs to react to state changes deep inside the interpreter — a variable being updated in Python, a child agent being spawned, or a message appearing on a channel. Polling these objects is inefficient and error-prone. dart_monty uses [signals_core](https://pub.dev/packages/signals_core) to provide a rich, reactive API for all internal state.

> **Note**: All signals have plain getter equivalents (e.g., `p.stateSignal.value` vs `p.state`) for non-reactive callers, enabling progressive disclosure of the reactive API.

## All signals at a glance

| Signal | Type | Class | Plain getter | Use case |
|--------|------|-------|--------------|----------|
| `stateSignal` | `ReadonlySignal<MontyLifecycleState>` | `MontyStateMixin` | `isIdle`/`isActive`/`isDisposed` | Show reconnect banner on unexpected disposal |
| `sessionStateSignal` | `ReadonlySignal<Map<String,Object?>>` | `AgentSession` | `state` | Live "Variables" inspector panel |
| `channelStateSignal` | `ReadonlySignal<BridgeChannelState>` | `EventLoopPlugin` | `channelState` | Show/hide input field on BridgeChannelWaiting |
| `lastEmittedSignal` | `ReadonlySignal<Map<String,dynamic>?>` | `EventLoopPlugin` | `lastEmitted` | Stream partial results from long Python computation |
| `childrenSignal` | `ReadonlySignal<Map<int,ChildState>>` | `SandboxPlugin` | — | Render active sub-agent list |
| `aliveCountSignal` | `Computed<int>` | `SandboxPlugin` | — | Gate "run another" button on aliveCount < max |
| `snapshotSignal` | `ReadonlySignal<ChannelSnapshot>` | `MessageChannel` | `snapshot` | Queue depth badge |
| `channelsSignal` | `ReadonlySignal<Map<String,...>>` | `MessageBus` | — | Dynamic channel list |

## Session lifecycle — `stateSignal`

The `stateSignal` is available on any class implementing `MontyStateMixin`, including all backends (`MontyFfi`, `MontyWasm`) and the `AgentSession` facade.

```dart
effect(() {
  if (platform.stateSignal.value == MontyLifecycleState.disposed) {
    showReconnectBanner();
  }
});
```

## Python variable state — `sessionStateSignal`

`AgentSession` tracks the global variable state of the Python interpreter. When a variable is assigned or modified in Python, the `sessionStateSignal` emits the updated state map.

```dart
effect(() {
  final state = session.sessionStateSignal.value;
  inspector.update(state);
});
```

## Execution turn — `channelStateSignal` + `lastEmittedSignal`

`EventLoopPlugin` provides reactivity for the execution loop. `channelStateSignal` tracks whether the interpreter is idle, running, or waiting for external input. `lastEmittedSignal` captures data emitted via `msg_emit()` (or similar mechanisms) during a run.

```dart
effect(() {
  final isWaiting = session.plugin<EventLoopPlugin>().channelStateSignal.value == BridgeChannelState.waiting;
  inputField.setVisible(isWaiting);
});

effect(() {
  final partial = session.plugin<EventLoopPlugin>().lastEmittedSignal.value;
  if (partial != null) stream.add(partial);
});
```

## Sub-agents — `childrenSignal` + `aliveCountSignal`

`SandboxPlugin` exposes the state of all child interpreters. `childrenSignal` provides the full map of child states, while `aliveCountSignal` is a computed signal for the number of currently running children.

```dart
effect(() {
  final children = session.plugin<SandboxPlugin>().childrenSignal.value;
  childList.render(children.values);
});

effect(() {
  final count = session.plugin<SandboxPlugin>().aliveCountSignal.value;
  spawnButton.setEnabled(count < maxChildren);
});
```

## Messaging — `snapshotSignal` + `channelsSignal`

The messaging system provides reactivity for both individual channels and the global message bus.

```dart
// Individual channel depth
effect(() {
  final depth = channel.snapshotSignal.value.depth;
  badge.setText(depth.toString());
});

// Global channel discovery
effect(() {
  final channelNames = session.plugin<MessageBusPlugin>().bus.channelsSignal.value.keys;
  sidebar.updateChannels(channelNames);
});
```
