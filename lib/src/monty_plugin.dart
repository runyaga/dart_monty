import 'package:dart_monty/src/bridge_logger.dart';
import 'package:dart_monty/src/host_function.dart';
import 'package:dart_monty/src/monty_backend_kind.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/attach_context.dart';
import 'package:dart_monty/src/extension_coordinator.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// ChildPolicy
// ---------------------------------------------------------------------------

/// How an extension participates when a child sandbox is spawned.
///
/// Replaces the old `createChildInstance() → MontyExtension?` nullable signature,
/// where `null` ambiguously meant "intentionally excluded" or "forgot to
/// implement." Each extension now declares intent explicitly.
enum ChildPolicy {
  /// The extension contributes a fresh instance to each child sandbox.
  ///
  /// `ExtensionCoordinator.spawnChild` calls [MontyExtension.createChildInstance];
  /// the returned instance must be a *new* object (not `this`).
  clone,

  /// The child sandbox shares the parent extension's instance directly.
  ///
  /// No new object is created; the same extension is attached to both the
  /// parent and each child coordinator. Use for extensions backed by shared
  /// infrastructure that tolerates multiple registrations safely.
  inherit,

  /// The extension is not present in child sandboxes. Default.
  ///
  /// This is the safe default — extensions opt into child propagation
  /// explicitly by overriding [MontyExtension.childPolicy].
  exclude,
}

// ---------------------------------------------------------------------------
// ChildSpawnContext
// ---------------------------------------------------------------------------

/// Context passed to [MontyExtension.createChildInstance] when a child sandbox
/// is spawned.
///
/// Carries the child's unique [childId] and an optional [workingDirectory]
/// that the consumer can use for per-child filesystem isolation.
class ChildSpawnContext {
  /// Creates a [ChildSpawnContext].
  const ChildSpawnContext({required this.childId, this.workingDirectory});

  /// Unique identifier for this child within the parent `SandboxExtension`.
  final int childId;

  /// Per-child working directory path, or `null` if the parent did not
  /// configure `SandboxExtension.sandboxBaseDir`.
  ///
  /// This is a computed path string only — actual directory creation is the
  /// consumer's responsibility (e.g., in `FsExtension.createChildInstance`).
  final String? workingDirectory;
}

// ---------------------------------------------------------------------------
// MontyExtension
// ---------------------------------------------------------------------------

/// Extension point for providing host functions to an [AttachContext].
///
/// Each extension declares a unique [namespace], a set of [functions], and
/// optional lifecycle hooks ([onAttach], [onDispose]).
///
/// ## Coordinator injection
///
/// After `ExtensionCoordinator.attachTo` runs, [coordinator] is set to the
/// owning coordinator. Extensions that need to spawn children or drive
/// lifecycle operations reach for it directly (see [SandboxExtension]).
///
/// Cross-extension communication goes through the bridge — invoke another
/// extension's function via `MontyRuntime.invoke(name, args)` rather than
/// holding a reference to a peer extension.
///
/// Accessing [coordinator] before `attachTo` is called throws a
/// `LateInitializationError`.
///
/// ## OS contributions
///
/// Extensions that need to intercept OS calls return a prefix map from
/// [osContribution]. `ExtensionCoordinator.attachTo` merges contributions from all
/// extensions, throws [StateError] if two extensions claim the same prefix, and
/// calls `bridge.registerOs` with the composed handler:
///
/// ```dart
/// @override
/// Map<String, OsCallHandler>? get osContribution => {
///   'Path.': _myFsHandler,
///   'os.getcwd': _myFsHandler,
/// };
/// ```
abstract class MontyExtension {
  /// Unique namespace prefix (e.g., `"df"`, `"chart"`, `"sqlite"`).
  String get namespace;

  /// Backends this extension supports.
  ///
  /// `ExtensionCoordinator.attachTo` checks [currentBackendKind] against this set
  /// and throws [UnsupportedBackendError] before any script runs if the
  /// extension declares it cannot operate on the current backend.
  ///
  /// Defaults to all backends. Override to `{MontyBackendKind.ffi}` or
  /// `{MontyBackendKind.wasm}` if the extension depends on capabilities that
  /// only exist on one backend (e.g., `SandboxExtension` needs `dart:io` + a
  /// second interpreter instance, which crashes the parent session on WASM).
  Set<MontyBackendKind> get supportedBackends => const {
    MontyBackendKind.ffi,
    MontyBackendKind.wasm,
  };

  /// Attachment priority — higher values attach first and dispose last.
  ///
  /// `ExtensionCoordinator.attachTo` sorts extensions in descending priority order
  /// before calling [onAttach]. Equal-priority extensions preserve insertion
  /// order (stable sort). Default is `0`.
  ///
  /// Use a positive value to run [onAttach] early (e.g., a logging/tracing
  /// extension that other extensions depend on). Use a negative value to run late
  /// (e.g., an extension that wraps peers it discovers via the bridge).
  int get priority => 0;

  /// Logger for this extension, injected by `ExtensionCoordinator` during attachment.
  ///
  /// Extensions should use this for all logging — never create loggers
  /// independently via `LogManager.instance.getLogger()`.
  ///
  /// Defaults to [NullBridgeLogger] (silent) until the coordinator sets it.
  BridgeLogger logger = const NullBridgeLogger();

  /// The owning coordinator, injected during [ExtensionCoordinator.attachTo].
  ///
  /// Extensions that spawn children or drive lifecycle operations reach for
  /// this field directly (see `SandboxExtension`). For cross-extension calls,
  /// prefer `MontyRuntime.invoke(name, args)` over holding references to
  /// peer extensions.
  ///
  /// Accessing this field before `attachTo` has been called throws a
  /// `LateInitializationError`.
  late ExtensionCoordinator coordinator;

  /// Human-readable description for LLM system prompt.
  ///
  /// Return `null` if the extension has no additional prompt context beyond
  /// its function schemas.
  String? get systemPromptContext => null;

  /// OS call prefix contributions for this extension.
  ///
  /// Each key is an operation-name prefix (e.g., `'Path.'`, `'os.'`); the
  /// value is the [OsCallHandler] that handles those operations.
  ///
  /// `ExtensionCoordinator.attachTo` merges contributions from all extensions and
  /// throws [StateError] if two extensions claim the same prefix. Returns `null`
  /// (the default) if this extension does not intercept OS calls.
  Map<String, OsCallHandler>? get osContribution => null;

  /// Host functions this extension provides.
  List<HostFunction> get functions;

  /// Called when attached to an [AttachContext]. Default no-op.
  @mustCallSuper
  Future<void> onAttach(AttachContext ctx) async {}

  /// Called when session ends. Must be idempotent.
  @mustCallSuper
  Future<void> onDispose() async {
    // Default no-op.
  }

  /// Declares how this extension participates in child sandboxes.
  ///
  /// Default: [ChildPolicy.exclude] — the extension is not present in children.
  /// Override to [ChildPolicy.clone] (and implement [createChildInstance])
  /// or [ChildPolicy.inherit] (share this instance across children).
  ChildPolicy get childPolicy => ChildPolicy.exclude;

  /// Creates a fresh instance of this extension for a child sandbox.
  ///
  /// Called by `ExtensionCoordinator.spawnChild` **only when [childPolicy] is
  /// [ChildPolicy.clone]**. The returned instance must be a new object
  /// (not `this`) and is registered on a separate [AttachContext] and disposed
  /// with the child.
  ///
  /// [context] carries the child's ID and optional per-child working
  /// directory. Extensions that need filesystem isolation (e.g., `FsExtension`)
  /// can use [ChildSpawnContext.workingDirectory] to create a private
  /// directory for the child.
  ///
  /// The default throws [UnsupportedError]: an extension with
  /// `childPolicy == clone` must override this method.
  MontyExtension createChildInstance(ChildSpawnContext context) {
    throw UnsupportedError(
      'Extension $runtimeType has childPolicy == ChildPolicy.clone but did not '
      'override createChildInstance(). Either override it to return a fresh '
      'instance, or set childPolicy to ChildPolicy.inherit / ChildPolicy.exclude.',
    );
  }
}
