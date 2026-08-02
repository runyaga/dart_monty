@TestOn('vm')
library;

// Engine-backed: MontyRuntime boots the FFI engine. dart_monty's chrome job
// deliberately covers only engine-free handler logic (see ci.yaml test-wasm);
// the end-to-end web path is covered by dart_monty_core's WASM fixture corpus.
// Regression test for the dart_monty_core 0.19 breaking change:
//
//   "A hand-built `{'__type': ...}` Dart `Map` is no longer honoured as that
//    type — it is a dict."  (dart_monty_core CHANGELOG.md, 0.19.0 Breaking)
//
// Host callback returns are routed through `MontyValue.encodeForWire`, so an
// envelope-shaped Map built by `timeHandler` arrives in sandboxed Python as a
// plain dict. `date.today().year` then raises `AttributeError` instead of
// returning an int, with no error at the boundary — the change "fails quietly".
//
// These tests assert the CORRECT behaviour: `date.today()` and `datetime.now()`
// must arrive as real Python date/datetime objects. They fail against a
// timeHandler that returns hand-built Maps and pass once it returns
// `MontyDate`/`MontyDateTime`.
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  // A frozen clock keeps these deterministic — never assert on "today".
  final frozen = DateTime(2024, 3, 15, 10, 30, 45);
  final time = timeHandler(clock: () => frozen);

  group('timeHandler returns typed values across the boundary', () {
    test('date.today() is a Python date, and .year is an int', () async {
      final session = MontyRuntime(
        osHandlers: {'date.': time, 'datetime.': time},
      );
      addTearDown(session.dispose);

      final result = await session
          .execute(
            'from datetime import date\n'
            'd = date.today()\n'
            '{"type": type(d).__name__, "year": d.year, "month": d.month, '
            '"day": d.day}',
          )
          .result;

      expect(result.error, isNull, reason: 'attribute access must not raise');
      final v = result.value.dartValue! as Map<String, Object?>;
      expect(v['type'], 'date', reason: 'must be a date, not a dict');
      expect(v['year'], frozen.year);
      expect(v['month'], frozen.month);
      expect(v['day'], frozen.day);
    });

    test('datetime.now() is a Python datetime and keeps its offset', () async {
      final session = MontyRuntime(
        osHandlers: {'date.': time, 'datetime.': time},
      );
      addTearDown(session.dispose);

      final result = await session
          .execute(
            // NB: monty implements a subset of CPython's datetime — there is
            // no utcoffset(). tzinfo is present, so assert on that.
            'from datetime import datetime\n'
            'n = datetime.now()\n'
            '{"type": type(n).__name__, "hour": n.hour, "minute": n.minute, '
            '"naive": n.tzinfo is None, "tz": repr(n.tzinfo)}',
          )
          .result;

      expect(result.error, isNull);
      final v = result.value.dartValue! as Map<String, Object?>;
      // monty reports the qualified name here ('datetime.datetime') while
      // `date` reports the bare 'date' — assert what it actually emits.
      expect(
        v['type'],
        'datetime.datetime',
        reason: 'must be a datetime, not a dict',
      );
      expect(v['hour'], frozen.hour);
      expect(v['minute'], frozen.minute);
      // The pre-0.19 handler emitted offset_seconds/timezone_name. Converting
      // via a bare Dart DateTime would drop both (MontyValue.fromDart calls
      // .toUtc(), leaving offsetSeconds/timezoneName null), so pin that the
      // datetime is tz-aware and carries this machine's zone name.
      expect(
        v['naive'],
        isFalse,
        reason: 'offsetSeconds must not be silently dropped',
      );
      expect(
        v['tz']! as String,
        contains(frozen.timeZoneName),
        reason: 'timezoneName must survive the boundary',
      );
    });
  });
}
