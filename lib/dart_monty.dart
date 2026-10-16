/// Pure Dart bindings for the Monty sandboxed Python interpreter.
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
///
/// final value = await Monty.withPool(
///   (monty) => monty.withSession((session) => session.feedRun('2 + 2')),
/// );
/// print(value); // MontyInt(4)
/// ```
library;

export 'package:dart_monty_core/dart_monty_core.dart'
        // Keep the order of the approved nine-name facade.
        // ignore: combinators_ordering
        show
        Monty,
        MontySession,
        MontyValue,
        MontyNone,
        MontyError,
        ResourceLimits,
        OsHandler,
        OsCallNotHandledException,
        ExternalException;

export 'src/bridge/bridge.dart' show MontyBridge;
export 'src/bridge/event.dart'
    show
        BridgeCallFinished,
        BridgeCallStarted,
        BridgeChildEvent,
        BridgeEvent,
        BridgeFunctionCallArgs,
        BridgeFunctionCallEnd,
        BridgeFunctionCallResult,
        BridgeFunctionCallStart,
        BridgeFunctionEmit,
        BridgeOsCallResult,
        BridgeOsCallStart,
        BridgeRunError,
        BridgeRunFinished,
        BridgeRunStarted;
export 'src/bridge/logger.dart' show BridgeLogger;
export 'src/extension/attach_context.dart' show AttachContext;
export 'src/extension/extension.dart'
    show ChildPolicy, ChildSpawnContext, MontyExtension;
export 'src/extensions/event_loop.dart' show EventLoopExtension;
export 'src/extensions/run_script.dart' show buildRunScriptFunction;
export 'src/extensions/sandbox.dart'
    show
        ChildCompleted,
        ChildDisposed,
        ChildFailed,
        ChildRunning,
        ChildSandboxException,
        ChildState,
        SandboxExtension;
export 'src/host/context.dart' show HostContext, HostSubExecutor;
export 'src/host/function.dart'
    show DispatchMode, HostFunction, HostFunctionHandler;
export 'src/host/param.dart' show HostParam;
export 'src/host/param_type.dart' show HostParamType;
export 'src/host/schema.dart' show HostFunctionSchema;
export 'src/runtime/backend_kind.dart' show MontyBackendKind;
export 'src/runtime/execution_handle.dart' show CancelToken, ExecutionHandle;
export 'src/runtime/runtime.dart' show MontyRuntime;
export 'src/runtime/runtime_ref.dart' show HostParentRef;
