@TestOn('vm')
library;

import 'dart:mirrors';

import 'package:dart_monty/dart_monty.dart' as dm;
import 'package:dart_monty/dart_monty_bridge.dart' as bridge;
import 'package:test/test.dart';

/// The names a library exports: its own public declarations and, through
/// each `export`, the target's exported names filtered by `show`/`hide`.
Set<String> _exported(LibraryMirror library, [Set<Uri>? seen]) {
  final visited = seen ?? <Uri>{};
  if (!visited.add(library.uri)) return {};
  final names = {
    for (final symbol in library.declarations.keys)
      if (!MirrorSystem.getName(symbol).startsWith('_'))
        MirrorSystem.getName(symbol),
  };
  for (final dependency in library.libraryDependencies) {
    if (!dependency.isExport) continue;
    final target = dependency.targetLibrary;
    if (target == null) continue;
    var visible = _exported(target, visited);
    for (final combinator in dependency.combinators) {
      final listed = combinator.identifiers.map(MirrorSystem.getName).toSet();
      visible = combinator.isShow
          ? visible.intersection(listed)
          : visible.difference(listed);
    }
    names.addAll(visible);
  }

  return names;
}

LibraryMirror _library(String uri) =>
    currentMirrorSystem().libraries[Uri.parse(uri)]!;

/// The public instance members [type] declares or inherits.
Set<String> _members(Type type) => {
  for (final symbol in reflectClass(type).instanceMembers.keys)
    MirrorSystem.getName(symbol),
};

void main() {
  // Both barrels are imported, so both are loaded.
  final public = {
    ..._exported(_library('package:dart_monty/dart_monty.dart')),
    ..._exported(_library('package:dart_monty/dart_monty_bridge.dart')),
  };

  test('the barrels still export what D1 keeps', () {
    expect(
      public,
      containsAll([
        'MontyRuntime',
        'MontyExtension',
        'EventLoopExtension',
        'MessageBusExtension',
        'MessageBus',
        'MessageChannel',
        'ChannelSnapshot',
        'BridgeLogger',
        'HostFunction',
        'HostFunctionSchema',
        'HostContext',
        'buildRunScriptFunction',
        'MontyBackendKind',
        'ChildPolicy',
        'ChildSpawnContext',
      ]),
    );
  });

  test('D1-6, D1-7 and D1-9 names are not public', () {
    expect(
      public.intersection({
        // D1-6
        'ChildPropagation', 'HostArgs', 'mapAndValidate',
        // D1-7
        'ExtensionCoordinator', 'coordinatorOf', 'runtimeCoordinator',
        'NullBridgeLogger', 'StructLogBridgeLogger',
        'UnsupportedBackendError', 'currentBackendKind',
        // D1-9
        'EventLoopState', 'EventLoopIdle', 'EventLoopExecuting',
        'EventLoopWaiting', 'EventLoopCompleted', 'EventLoopDisposed',
        'EventLoopChannel',
      }),
      isEmpty,
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
