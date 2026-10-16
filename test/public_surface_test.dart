// The public surface of dart_monty's two libraries, by name.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:dart_monty/dart_monty.dart' as dm;
import 'package:dart_monty/dart_monty_bridge.dart' as bridge;
import 'package:test/test.dart';

/// The names a library exports, each with the library that declares it:
/// its own public declarations and, through each `export`, the target's
/// exported names filtered by `show`/`hide`. Function type aliases are not
/// reflected; [_typeAliases] checks those.
Map<String, Uri> _exported(LibraryMirror library) {
  final names = <String, Uri>{
    for (final symbol in library.declarations.keys)
      if (!MirrorSystem.getName(symbol).startsWith('_'))
        MirrorSystem.getName(symbol): library.uri,
  };
  for (final dependency in library.libraryDependencies) {
    if (!dependency.isExport) continue;
    final target = dependency.targetLibrary;
    if (target == null) continue;
    var visible = _exported(target);
    for (final combinator in dependency.combinators) {
      final listed = combinator.identifiers.map(MirrorSystem.getName).toSet();
      visible = {
        for (final MapEntry(:key, :value) in visible.entries)
          if (listed.contains(key) == combinator.isShow) key: value,
      };
    }
    names.addAll(visible);
  }

  return names;
}

LibraryMirror _library(String uri) =>
    currentMirrorSystem().libraries[Uri.parse(uri)]!;

bool _isCore(Uri uri) => uri.toString().startsWith('package:dart_monty_core/');

/// The names [uri] exports that dart_monty itself declares.
Set<String> _own(String uri) => {
  for (final MapEntry(:key, :value) in _exported(_library(uri)).entries)
    if (!_isCore(value)) key,
};

/// The `show` list of [uri]'s export of core's main library; null for an
/// export without one, the whole library.
Set<String>? _coreShow(String uri) {
  final exports = [
    for (final dependency in _library(uri).libraryDependencies)
      if (dependency.isExport &&
          dependency.targetLibrary?.uri.toString() ==
              'package:dart_monty_core/dart_monty_core.dart')
        dependency,
  ];
  expect(exports, hasLength(1), reason: '$uri exports core once');
  final shows = exports.single.combinators.where((c) => c.isShow).toList();
  if (shows.isEmpty) return null;

  return {
    for (final show in shows) ...show.identifiers.map(MirrorSystem.getName),
  };
}

/// The public instance members [type] declares or inherits.
Set<String> _members(Type type) => {
  for (final symbol in reflectClass(type).instanceMembers.keys)
    MirrorSystem.getName(symbol),
};

// The function type aliases the libraries export: a compile-time check,
// since mirrors do not list them.
const _typeAliases = [bridge.HostFunctionHandler, bridge.HostSubExecutor];

/// What `dart_monty_bridge.dart` exports of dart_monty's own names at D1:
/// the names surface pass 1 keeps, plus those whose removal belongs to a
/// later step (D1-8, deferred: the child states and the child exception;
/// D4: the filesystem handlers and `ChildVfsStrategy`).
const _bridgeNames = {
  // Runtime and execution.
  'MontyRuntime', 'MontyBridge', 'ExecutionHandle', 'CancelToken',
  'HostParentRef',
  // Host functions.
  'HostFunction', 'DispatchMode', 'HostFunctionSchema', 'HostParam',
  'HostParamType', 'HostContext',
  // Events and logging.
  'BridgeEvent', 'BridgeRunStarted', 'BridgeRunFinished', 'BridgeRunError',
  'BridgeCallStarted', 'BridgeCallFinished', 'BridgeChildEvent',
  'BridgeFunctionCallStart', 'BridgeFunctionCallArgs',
  'BridgeFunctionCallResult', 'BridgeFunctionCallEnd', 'BridgeFunctionEmit',
  'BridgeOsCallStart', 'BridgeOsCallResult', 'BridgeLogger',
  // Extension contract.
  'MontyExtension', 'AttachContext', 'MontyBackendKind', 'ChildPolicy',
  'ChildSpawnContext',
  // Bundled extensions.
  'EventLoopExtension', 'MessageBusExtension', 'MessageBus',
  'MessageChannel', 'ChannelSnapshot', 'SandboxExtension',
  'buildRunScriptFunction',
  // OS calls.
  'defaultOsHandler',
  // D1-8 (deferred) makes these private.
  'ChildState', 'ChildRunning', 'ChildCompleted', 'ChildFailed',
  'ChildDisposed',
  'ChildSandboxException',
  // D4 deletes these.
  'ChildVfsStrategy', 'fsHandler', 'memoryFsHandler', 'overlayFsHandler',
  'readOnlyHandler', 'DecoratorHandlers.overlayWith',
  'DecoratorHandlers.readOnly', 'envHandler', 'sandboxedFsHandler',
};

void main() {
  const main = 'package:dart_monty/dart_monty.dart';
  const bridgeLib = 'package:dart_monty/dart_monty_bridge.dart';
  final public = {..._own(main), ..._own(bridgeLib)};

  group('dart_monty.dart', () {
    test('exports MontyRuntime and HostParentRef of its own', () {
      expect(_own(main), {'MontyRuntime', 'HostParentRef'});
    });

    test('re-exports the whole of core until the curated list (D2)', () {
      expect(_coreShow(main), isNull);
      // Core's eight kept names resolve through it.
      expect(
        [
          dm.Monty,
          dm.MontySession,
          dm.MontyValue,
          dm.MontyError,
          dm.ResourceLimits,
          dm.OsCallNotHandledException,
          dm.ExternalException,
        ],
        hasLength(7),
      );
    });

    test('does not export MontyValueX', () {
      expect(
        _exported(_library(main)).keys.where((n) => n.contains('MontyValueX')),
        isEmpty,
      );
    });
  });

  group('dart_monty_bridge.dart', () {
    test('exports exactly the D1 names of its own', () {
      expect(_own(bridgeLib).difference(_bridgeNames), isEmpty);
      expect(_bridgeNames.difference(_own(bridgeLib)), isEmpty);
      expect(_typeAliases, hasLength(2));
    });

    test('re-exports only ExternalException and OsHandler from core', () {
      expect(_coreShow(bridgeLib), {'ExternalException', 'OsHandler'});
      expect(
        _exported(_library(bridgeLib)).keys,
        isNot(contains('wrappedValue')),
      );
    });
  });

  test("each library exports only its own sources and core's main "
      'library: no test double, fake pool or core testing library', () {
    for (final uri in [main, bridgeLib]) {
      final targets = {
        for (final dependency in _library(uri).libraryDependencies)
          if (dependency.isExport) '${dependency.targetLibrary?.uri}',
      };
      expect(
        targets.where(
          (t) =>
              !t.startsWith('package:dart_monty/src/') &&
              t != 'package:dart_monty_core/dart_monty_core.dart',
        ),
        isEmpty,
        reason: uri,
      );
      expect(
        _exported(_library(uri)).keys,
        isNot(contains('FakeMontySession')),
      );
    }
  });

  test('names D1 makes private are not public', () {
    expect(
      public.intersection({
        // D1-4
        'MontyRuntimeRef', 'currentBackendKind', 'startRuntimeWith',
        'defaultPoolSize', 'RuntimeCheckout', 'extractBridgeResult',
        // D1-5
        'composeOsHandlers', 'osArgString', 'PathOp', 'timeHandler',
        // D1-6
        'ChildPropagation', 'HostArgs', 'mapAndValidate',
        // D1-7
        'ExtensionCoordinator', 'coordinatorOf', 'runtimeCoordinator',
        'NullBridgeLogger', 'StructLogBridgeLogger',
        'UnsupportedBackendError',
        // D1-9
        'EventLoopState', 'EventLoopIdle', 'EventLoopExecuting',
        'EventLoopWaiting', 'EventLoopCompleted', 'EventLoopDisposed',
        'EventLoopChannel',
        // D1-11
        'MontyValueX', 'OsCallException',
      }),
      isEmpty,
    );
    expect(public.where((n) => n.startsWith('MontyValueX')), isEmpty);
  });

  test('names that are not part of dart_monty, or that D1 deletes, are '
      'absent', () {
    expect(
      public.intersection({
        'JinjaTemplateExtension', 'StatefulExtension', 'defaultExtensions',
        'DescriptionProvider', 'FunctionSurface', 'ParamRenderHint',
        'ChildSystemPromptBuilder', 'MontyInterceptor',
        // Deleted at D1, with no alias left behind.
        'PlatformBridge', 'DartMonty', 'MontyRepl', 'MontyPlatformFactory',
        'MontyResult', 'OsCallHandler',
      }),
      isEmpty,
    );
    for (final gone in ['monty_backend_spi.dart', 'dart_monty_testing.dart']) {
      expect(File('lib/$gone').existsSync(), isFalse, reason: gone);
    }
    expect(
      Directory('lib')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet(),
      {'dart_monty.dart', 'dart_monty_bridge.dart'},
    );
  });

  test('removed members are gone from the public classes', () {
    expect(_members(bridge.HostFunction), isNot(contains('childPropagation')));
    expect(
      _members(bridge.HostFunctionSchema),
      isNot(contains('mapAndValidate')),
    );
    expect(_members(bridge.MontyExtension), isNot(contains('coordinator')));
    expect(
      _members(dm.MontyRuntime),
      isNot(anyOf(contains('coordinator'), contains('subExecute'))),
    );
    expect(
      _members(bridge.EventLoopExtension),
      isNot(anyOf(contains('channelState'), contains('channelStateSignal'))),
    );
  });
}
