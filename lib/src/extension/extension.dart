import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/extension/attach_context.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/runtime/backend_kind.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// ChildPolicy
// ---------------------------------------------------------------------------

/// Selects an extension's participation in child sandboxes.
enum ChildPolicy {
  /// Calls [MontyExtension.createChildInstance] for a distinct instance in
  /// each child.
  clone,

  /// Attaches the parent extension instance to each child.
  inherit,

  /// Omits the extension from child sandboxes.
  exclude,
}

// ---------------------------------------------------------------------------
// ChildSpawnContext
// ---------------------------------------------------------------------------

/// Identifies the child passed to [MontyExtension.createChildInstance].
class ChildSpawnContext {
  /// Describes one child and its optional virtual working directory.
  // ignore: unnecessary-nullable-parameters, public D1 signature retains optional cwd.
  const ChildSpawnContext({required this.childId, this.workingDirectory});

  /// Unique identifier for this child within the parent `SandboxExtension`.
  final int childId;

  /// Provides the virtual child directory without exposing native backing.
  // ignore: unnecessarily-public-code, consumed by external clone-policy extensions.
  final String? workingDirectory;
}

// ---------------------------------------------------------------------------
// MontyExtension
// ---------------------------------------------------------------------------

/// Groups host capabilities under one attachment and disposal lifecycle.
abstract class MontyExtension {
  /// Provides the unique prefix required on every contributed function name.
  String get namespace;

  /// Declares the backends accepted before attachment begins.
  Set<MontyBackendKind> get supportedBackends => const {
    MontyBackendKind.ffi,
    MontyBackendKind.wasm,
  };

  /// Orders attachment from high to low and preserves registration order for
  /// ties.
  int get priority => 0;

  /// Receives the scoped logger during attachment. Extensions use it instead
  /// of creating independent loggers.
  BridgeLogger logger = BridgeLogger.silent;

  /// Adds extension context to an LLM prompt when non-null.
  String? get systemPromptContext => null;

  /// Contributes OS handlers with prefixes unique across extensions.
  Map<String, OsHandler>? get osContribution => null;

  /// Provides host functions whose names begin with [namespace].
  List<HostFunction> get functions;

  /// Initializes resources after functions and OS handlers are registered.
  @mustCallSuper
  Future<void> onAttach(AttachContext ctx) async {}

  /// Releases extension resources and must be idempotent.
  @mustCallSuper
  Future<void> onDispose() async {
    // Default no-op.
  }

  /// Excludes the extension from child sandboxes unless overridden.
  ChildPolicy get childPolicy => ChildPolicy.exclude;

  /// Creates a distinct separately attached child instance or throws
  /// [UnsupportedError] for an unimplemented clone policy.
  MontyExtension createChildInstance(ChildSpawnContext context) {
    throw UnsupportedError(
      'Extension $runtimeType has childPolicy == ChildPolicy.clone but did not '
      'override createChildInstance(). Either override it to return a fresh '
      'instance, or set childPolicy to ChildPolicy.inherit / ChildPolicy.exclude.',
    );
  }
}
