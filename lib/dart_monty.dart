/// Runs restricted Python through native and web workers.
///
/// The package does not follow semantic versioning. The package expects to
/// stabilize its API and adopt semantic versioning within one to three months.
library;

/// Re-exports core primitives.
export 'package:dart_monty_core/dart_monty_core.dart'
        // Keep the order of the approved 25-name facade.
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
        ExternalException,
        OSAccess,
        MontyBool,
        MontyInt,
        MontyFloat,
        MontyString,
        MontyList,
        MontyTuple,
        MontyDict,
        MontyBytes,
        Frame,
        MontyRuntimeError,
        MontySyntaxError,
        MontyTypingError,
        MontyCrashedError,
        MontyExceptionValue,
        FrameTooLargeException;

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
export 'src/extensions/sandbox.dart' show SandboxExtension;
export 'src/host/context.dart' show HostContext, HostSubExecutor;
export 'src/host/function.dart'
    show
        DispatchMode,
        HostFunction,
        HostFunctionHandler,
        ParityHostFunctionHandler;
export 'src/host/param.dart' show HostParam;
export 'src/host/param_type.dart' show HostParamType;
export 'src/host/schema.dart' show HostFunctionSchema;
export 'src/runtime/backend_kind.dart' show MontyBackendKind;
export 'src/runtime/execution_handle.dart' show CancelToken, ExecutionHandle;
export 'src/runtime/runtime.dart' show MontyRuntime;
export 'src/runtime/runtime_ref.dart' show HostParentRef;
