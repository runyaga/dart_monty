@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../src/workspace/bounds_test.dart' as bounds;
import '../src/workspace/caps_test.dart' as caps;

void main() {
  late Directory base;
  setUp(() {
    Directory('build').createSync();
    base = Directory('build').createTempSync('native-policy-');
  });
  tearDown(() {
    // Every published workspace must have disposed its owned backing.
    expect(base.listSync(), isEmpty);
    base.deleteSync(recursive: true);
  });
  group('native caps', () => caps.registerCapsTests(backing: () => base.path));
  group(
    'native bounds',
    () => bounds.registerBoundsTests(backing: () => base.path),
  );
}
