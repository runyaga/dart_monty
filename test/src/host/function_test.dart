import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

Future<Object?> _a(Map<String, Object?> args, HostContext ctx) async => 'a';
Future<Object?> _b(Map<String, Object?> args, HostContext ctx) async => 'b';
Future<Object?> _c(Map<String, Object?> args, HostContext ctx) async => 'c';

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
}
