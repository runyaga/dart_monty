@TestOn('vm')
library;

// `datetime.now(tz)` semantics, per monty v0.0.19's own contract.
//
// `OsFunctionCall::DateTimeNow(Option<MontyTimeZone>)` carries the requested
// timezone and documents "`None` for a naive result"
// (monty crates/monty-types/src/os.rs). Upstream's reference embedder,
// `dispatch_datetime_now` in crates/monty-datatest/src/main.rs, implements it as:
//
//   tz absent  -> local wall-clock, offset_seconds: None, timezone_name: None
//   tz present -> the same instant converted into that zone, carrying its
//                 offset and name
//
// CPython agrees: `datetime.now()` is naive, `datetime.now(tz)` is aware in tz.
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  // Frozen local clock. Expectations derive from it, never hard-coded, so this
  // passes in any host timezone.
  final frozen = DateTime(2024, 3, 15, 10, 30, 45);
  final time = timeHandler(clock: () => frozen);

  MontyRuntime newSession() =>
      MontyRuntime(osHandlers: {'date.': time, 'datetime.': time});

  group('datetime.now honours the requested timezone', () {
    test('no argument yields a NAIVE datetime', () async {
      final session = newSession();
      addTearDown(session.dispose);

      final r = await session
          .execute(
            'from datetime import datetime\n'
            'n = datetime.now()\n'
            '{"naive": n.tzinfo is None, "hour": n.hour, "minute": n.minute}',
          )
          .result;

      expect(r.error, isNull);
      final v = r.value.dartValue! as Map<String, Object?>;
      expect(v['naive'], isTrue, reason: 'datetime.now() must be naive');
      // Naive means LOCAL wall clock, so the frozen local fields come through.
      expect(v['hour'], frozen.hour);
      expect(v['minute'], frozen.minute);
    });

    test('a requested zone shifts the instant', () async {
      final session = newSession();
      addTearDown(session.dispose);

      final r = await session
          .execute(
            // NB: monty's timezone implements no utcoffset(); repr is the
            // observable surface, so assert on that.
            // A NON-ZERO offset on purpose. Requesting UTC makes this
            // tautological on a UTC host, where the unshifted local wall clock
            // already equals the UTC one — measured: with the shift removed,
            // the UTC form passed under TZ=UTC and failed only under
            // TZ=America/Chicago. GitHub runners are UTC.
            'from datetime import datetime, timezone, timedelta\n'
            'u = datetime.now(timezone(timedelta(hours=4)))\n'
            '{"naive": u.tzinfo is None, "hour": u.hour, '
            '"minute": u.minute, "tz": repr(u.tzinfo)}',
          )
          .result;

      expect(r.error, isNull);
      final v = r.value.dartValue! as Map<String, Object?>;
      expect(v['naive'], isFalse, reason: 'datetime.now(tz) must be aware');
      // The instant shifted into +04:00, independent of the host's zone.
      final expected = frozen.toUtc().add(const Duration(hours: 4));
      expect(v['hour'], expected.hour);
      expect(v['minute'], expected.minute);
    });

    test('date.today is unaffected', () async {
      final session = newSession();
      addTearDown(session.dispose);

      final r = await session
          .execute(
            'from datetime import date\n'
            'd = date.today()\n'
            '{"y": d.year, "m": d.month, "d": d.day}',
          )
          .result;

      expect(r.error, isNull);
      final v = r.value.dartValue! as Map<String, Object?>;
      expect(v['y'], frozen.year);
      expect(v['m'], frozen.month);
      expect(v['d'], frozen.day);
    });
  });
}
