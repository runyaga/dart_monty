/// Minimal test to verify DartMontyBridge JS loads and initializes.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'package:test/test.dart';

@JS('DartMontyBridge')
external JSAny? get _dartMontyBridge;

@JS('DartMontyBridge.init')
external JSAny? get _initFn;

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _jsInit();

void main() {
  test('DartMontyBridge is registered on window', () {
    final bridge = _dartMontyBridge;
    expect(bridge, isNotNull, reason: 'window.DartMontyBridge must be defined');
  });

  test('DartMontyBridge.init is a function', () {
    final fn = _initFn;
    expect(fn, isNotNull, reason: 'DartMontyBridge.init must be defined');
  });

  test('DartMontyBridge.init() resolves to true (worker + WASM load)', () async {
    final result = await _jsInit().toDart;
    expect(result.toDart, isTrue, reason: 'init() must return true — Worker + WASM loaded');
  });
}
