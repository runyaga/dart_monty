import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/host/dispatch.dart';
import 'package:dart_monty/src/host/function.dart'
    show HostFunctionParityInternal;
import 'package:test/test.dart';

Future<MontyValue> _a(Map<String, MontyValue> args, HostContext ctx) async =>
    const MontyString('a');
Future<MontyValue> _b(Map<String, MontyValue> args, HostContext ctx) async =>
    const MontyString('b');
Future<MontyValue> _c(Map<String, MontyValue> args, HostContext ctx) async =>
    const MontyString('c');

Object? _pa(Map<String, MontyValue> args, HostContext ctx) => 'a';
Object? _pb(Map<String, MontyValue> args, HostContext ctx) => 'b';
Object? _pc(Map<String, MontyValue> args, HostContext ctx) => 'c';

const _schema = HostFunctionSchema(name: 'f');

void main() {
  test('handler installs one implementation on both backends', () {
    const fn = HostFunction(schema: _schema, handler: _a);

    expect(fn.ffiHandler, same(_a));
    expect(fn.wasmHandler, same(_a));
  });

  test('a backend-specific handler wins over handler', () {
    const fn = HostFunction(schema: _schema, handler: _a, ffiHandler: _b);
    const web = HostFunction(schema: _schema, handler: _a, wasmHandler: _c);

    expect(fn.ffiHandler, same(_b));
    expect(fn.wasmHandler, same(_a));
    expect(web.ffiHandler, same(_a));
    expect(web.wasmHandler, same(_c));
  });

  test('handler is the current backend slot', () {
    const fn = HostFunction(schema: _schema, ffiHandler: _b, wasmHandler: _c);
    const ffiOnly = HostFunction(schema: _schema, ffiHandler: _b);

    expect(fn.handler, same(_b));
    expect(ffiOnly.handler, same(_b));
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
      expect(fn.ffiParityHandler, same(_pa));
      expect(fn.wasmParityHandler, same(_pa));
      expect(fn.ffiHandler, isNull);
      expect(fn.wasmHandler, isNull);
      expect(fn.handler, isNull);
      expect(fn.dispatch, DispatchMode.sync);
    });

    test('a backend-specific handler wins over handler', () {
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

      expect(fn.ffiParityHandler, same(_pb));
      expect(fn.wasmParityHandler, same(_pa));
      expect(web.ffiParityHandler, same(_pa));
      expect(web.wasmParityHandler, same(_pc));
    });

    test('parityHandler is the current backend slot and skips inactive', () {
      const fn = HostFunction.parity(
        schema: _schema,
        ffiHandler: _pb,
        wasmHandler: _pc,
      );
      const ffiOnly = HostFunction.parity(schema: _schema, ffiHandler: _pb);
      const wasmOnly = HostFunction.parity(schema: _schema, wasmHandler: _pc);

      expect(fn.parityHandler, same(_pb));
      expect(ffiOnly.parityHandler, same(_pb));
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

      expect(fn.parityHandler, same(_pc));
      expect(ffiOnly.parityHandler, isNull);
      expect(wasmOnly.parityHandler, same(_pc));

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
