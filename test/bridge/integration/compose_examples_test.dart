@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

/// Composed-plugin examples — end-to-end scenarios for documentation.
///
/// Each test exercises a real composition of plugins + [OsCallHandler]s
/// through [AgentSession] to show downstream users how the pieces fit
/// together. Run with:
///
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/compose_examples_test.dart
/// ```
void main() {
  // ---------------------------------------------------------------------------
  // Example 1: Sandbox + MessageBus + VFS inheritance
  // ---------------------------------------------------------------------------

  /// Demonstrates:
  /// - `parentPlugins` so children inherit [MessageBusPlugin] (same bus).
  /// - `parentOsContributions` so `date./datetime.` flow into the child while
  ///   `Path.` is swapped for a fresh per-child memory VFS (by design).
  /// - `osHandlers:` composed at the parent so Python can read/write via
  ///   `pathlib` in the parent session.
  ///
  /// Scenario: parent writes a payload file to its own VFS, reads it, hands
  /// the contents to a child sandbox over the shared [MessageBus], the child
  /// transforms and replies. The parent asserts end-to-end delivery.
  test(
    'composed sandbox + message bus + VFS produces round-tripped payload',
    () async {
      final osContribs = <String, OsCallHandler>{
        'Path.': memoryFsHandler(),
        'date.': timeHandler(),
        'datetime.': timeHandler(),
      };
      final bus = MessageBusPlugin();
      final plugins = <MontyPlugin>[bus];
      plugins.add(
        SandboxPlugin(
          platformFactory: () async => createPlatformMonty(),
          parentPlugins: plugins,
          parentOsContributions: osContribs,
        ),
      );

      final session = AgentSession(osHandlers: osContribs, plugins: plugins);
      addTearDown(session.dispose);

      final result = await session.execute(r'''
from pathlib import Path

# Parent owns its VFS (child gets a fresh one — by design).
Path('/inbox/payload.txt').write_text('ping')
payload = Path('/inbox/payload.txt').read_text()

# Hand the payload to the child over the SHARED bus.
msg_send(name='jobs', message=payload)

# Child inherits MessageBusPlugin via parentPlugins — same bus underneath.
child_code = (
    "msg = msg_recv(name='jobs')\n"
    "msg_send(name='results', message=f'pong:{msg}')\n"
    "'ok'"
)
h = sandbox_spawn(code=child_code)
child_status = sandbox_await(handle=h)

# Parent pulls the child's reply off the shared bus.
reply = msg_recv(name='results')
[payload, child_status, reply]
''');

      expect(result.value.dartValue, ['ping', 'ok', 'pong:ping']);
    },
  );

  // ---------------------------------------------------------------------------
  // Example 2: Overlay VFS with read-only base
  // ---------------------------------------------------------------------------

  /// Demonstrates:
  /// - `overlayFsHandler(base:, scratch:)` composition.
  /// - `readOnlyHandler` wrapping the base to guarantee it is never mutated
  ///   even if the overlay's write-path implementation changed.
  /// - `osHandlers:` routing `Path.*` to the overlay.
  ///
  /// Scenario: the base ships pre-populated read-only config. Python reads
  /// it, writes a modified copy to scratch, and asserts the base layer is
  /// untouched after the run.
  test(
    'overlay VFS preserves read-only base while scratch captures writes',
    () async {
      final baseFs = MemoryFileSystem();
      baseFs.file('/config/settings.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('feature=on\nlimit=10');

      final scratchFs = MemoryFileSystem();

      final base = readOnlyHandler(fsHandler(baseFs));
      final scratch = fsHandler(scratchFs);
      final overlay = overlayFsHandler(base: base, scratch: scratch);

      final session = AgentSession(
        osHandlers: {
          'Path.': overlay,
          'date.': timeHandler(),
          'datetime.': timeHandler(),
        },
      );
      addTearDown(session.dispose);

      final result = await session.execute('''
from pathlib import Path

original = Path('/config/settings.txt').read_text()

# Modified copy lands in scratch.
modified = original.replace('limit=10', 'limit=99')
Path('/config/settings.txt').write_text(modified)

# Overlay read returns the scratch version.
after_write = Path('/config/settings.txt').read_text()

# A brand-new file also goes to scratch.
Path('/config/extra.txt').write_text('new')
extra_exists = Path('/config/extra.txt').exists()

[original, after_write, extra_exists]
''');

      expect(result.value.dartValue, [
        'feature=on\nlimit=10',
        'feature=on\nlimit=99',
        true,
      ]);

      // Base layer is pristine — the readOnly wrapper guarantees it.
      expect(
        baseFs.file('/config/settings.txt').readAsStringSync(),
        'feature=on\nlimit=10',
      );
      expect(baseFs.file('/config/extra.txt').existsSync(), isFalse);

      // Scratch captured the modifications.
      expect(
        scratchFs.file('/config/settings.txt').readAsStringSync(),
        'feature=on\nlimit=99',
      );
      expect(scratchFs.file('/config/extra.txt').readAsStringSync(), 'new');
    },
  );

  // ---------------------------------------------------------------------------
  // Example 3: Jinja + message bus + injected clock
  // ---------------------------------------------------------------------------

  /// Demonstrates:
  /// - `osHandlers:` routing `datetime.` through a `timeHandler(clock: ...)`
  ///   so tests observe deterministic timestamps.
  /// - Multi-plugin composition: [JinjaTemplatePlugin] + [MessageBusPlugin]
  ///   cooperating in the same Python script.
  ///
  /// Scenario: Python grabs the current time (from the injected clock),
  /// renders a Jinja template that embeds it, then publishes the rendered
  /// string onto a named bus channel. The test pulls the message off the
  /// Dart side of the bus and asserts it contains the frozen timestamp.
  test('template + bus + injected clock emits timestamped message', () async {
    final frozen = DateTime.utc(2026, 4, 18, 9, 30);
    final time = timeHandler(clock: () => frozen);

    final bus = MessageBusPlugin();

    final session = AgentSession(
      osHandlers: {'date.': time, 'datetime.': time},
      plugins: [JinjaTemplatePlugin(), bus],
    );
    addTearDown(session.dispose);

    final result = await session.execute('''
from datetime import datetime

stamp = datetime.now().isoformat()
rendered = tmpl_render(
    template='report[{{ ts }}]: {{ body }}',
    context={'ts': stamp, 'body': 'ready'},
)
msg_send(name='reports', message=rendered)
rendered
''');

    final rendered = result.value.dartValue! as String;

    // Deterministic clock → predictable prefix + body.
    expect(rendered, startsWith('report[2026-04-18T09:30:00'));
    expect(rendered, endsWith(': ready'));

    // Dart side observes the same rendered string on the shared bus.
    final delivered = await bus.bus.channel('reports').recv();
    expect(delivered, rendered);
  });
}
