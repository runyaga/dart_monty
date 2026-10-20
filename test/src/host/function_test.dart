import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/host/dispatch.dart';
import 'package:dart_monty/src/host/function.dart'
    show HostFunctionParityInternal;
import 'package:test/test.dart';

Future<MontyValue> _a(Map<String, MontyValue> args, HostContext ctx) =>
    Future.value(const MontyString('a'));
Future<MontyValue> _b(Map<String, MontyValue> args, HostContext ctx) =>
    Future.value(const MontyString('b'));
Future<MontyValue> _c(Map<String, MontyValue> args, HostContext ctx) =>
    Future.value(const MontyString('c'));

Object? _pa(Map<String, MontyValue> args, HostContext ctx) => 'a';
Object? _pb(Map<String, MontyValue> args, HostContext ctx) => 'b';
Object? _pc(Map<String, MontyValue> args, HostContext ctx) => 'c';

const _schema = HostFunctionSchema(name: 'f');

void main() {
  test('handler installs one implementation on both backends', () {
    const fn = HostFunction(schema: _schema, handler: _a);
    final matchesA = same(_a);

    expect(fn.ffiHandler, matchesA);
    expect(fn.wasmHandler, matchesA);
  });

  test('a backend-specific handler wins over handler', () {
    const fn = HostFunction(schema: _schema, handler: _a, ffiHandler: _b);
    const web = HostFunction(schema: _schema, handler: _a, wasmHandler: _c);
    final matchesA = same(_a);

    expect(fn.ffiHandler, same(_b));
    expect(fn.wasmHandler, matchesA);
    expect(web.ffiHandler, matchesA);
    expect(web.wasmHandler, same(_c));
  });

  test('handler is the current backend slot', () {
    const fn = HostFunction(schema: _schema, ffiHandler: _b, wasmHandler: _c);
    const ffiOnly = HostFunction(schema: _schema, ffiHandler: _b);
    final matchesB = same(_b);

    expect(fn.handler, matchesB);
    expect(ffiOnly.handler, matchesB);
  }, testOn: 'vm');

  test('handler is the wasm slot in a browser', () {
    const fn = HostFunction(schema: _schema, ffiHandler: _b, wasmHandler: _c);
    const ffiOnly = HostFunction(schema: _schema, ffiHandler: _b);

    expect(fn.handler, same(_c));
    expect(ffiOnly.handler, isNull);
  }, testOn: 'browser');

  test('dispatch defaults to sync', () {
    const fn = HostFunction(schema: _schema, handler: _a);

    expect(fn.dispatch, DispatchMode.sync);
  });

  group('HostFunction.parity', () {
    test('handler installs one implementation on both backends', () {
      const fn = HostFunction.parity(schema: _schema, handler: _pa);

      expect(fn.isParity, isTrue);
      expect(fn.hasActiveHandler, isTrue);
      expect(fn.parityHandler, same(_pa));
      expect(fn.ffiHandler, isNull);
      expect(fn.wasmHandler, isNull);
      expect(fn.handler, isNull);
      expect(fn.dispatch, DispatchMode.sync);
    });

    test('a backend-specific handler wins over handler on vm', () {
      const fn = HostFunction.parity(
        schema: _schema,
        handler: _pa,
        ffiHandler: _pb,
      );
      const web = HostFunction.parity(
        schema: _schema,
        handler: _pa,
        wasmHandler: _pc,
      );

      expect(fn.parityHandler, same(_pb));
      expect(web.parityHandler, same(_pa));
    }, testOn: 'vm');

    test('a backend-specific handler wins over handler in a browser', () {
      const fn = HostFunction.parity(
        schema: _schema,
        handler: _pa,
        ffiHandler: _pb,
      );
      const web = HostFunction.parity(
        schema: _schema,
        handler: _pa,
        wasmHandler: _pc,
      );

      expect(fn.parityHandler, same(_pa));
      expect(web.parityHandler, same(_pc));
    }, testOn: 'browser');

    test('parityHandler is the current backend slot and skips inactive', () {
      const fn = HostFunction.parity(
        schema: _schema,
        ffiHandler: _pb,
        wasmHandler: _pc,
      );
      const ffiOnly = HostFunction.parity(schema: _schema, ffiHandler: _pb);
      const wasmOnly = HostFunction.parity(schema: _schema, wasmHandler: _pc);
      final matchesPb = same(_pb);

      expect(fn.parityHandler, matchesPb);
      expect(ffiOnly.parityHandler, matchesPb);
      expect(wasmOnly.parityHandler, isNull);

      final dispatch = HostDispatch(
        log: BridgeLogger.silent,
        runtime: null,
        subExecute: null,
      )..register(wasmOnly);
      expect(dispatch.schemas, isEmpty);

      dispatch.register(ffiOnly);
      expect(dispatch.schemas, [_schema]);
    }, testOn: 'vm');

    test('parityHandler is the wasm slot in a browser and skips inactive', () {
      const fn = HostFunction.parity(
        schema: _schema,
        ffiHandler: _pb,
        wasmHandler: _pc,
      );
      const ffiOnly = HostFunction.parity(schema: _schema, ffiHandler: _pb);
      const wasmOnly = HostFunction.parity(schema: _schema, wasmHandler: _pc);
      final matchesPc = same(_pc);

      expect(fn.parityHandler, matchesPc);
      expect(ffiOnly.parityHandler, isNull);
      expect(wasmOnly.parityHandler, matchesPc);

      final dispatch = HostDispatch(
        log: BridgeLogger.silent,
        runtime: null,
        subExecute: null,
      )..register(ffiOnly);
      expect(dispatch.schemas, isEmpty);

      dispatch.register(wasmOnly);
      expect(dispatch.schemas, [_schema]);
    }, testOn: 'browser');
  });
}
