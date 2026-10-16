// Keep the existing CI browser glob on real core sessions. The cap suite uses
// portable imports and exercises open/read/write through the Web Worker.
@TestOn('browser')
library;

import 'package:test/test.dart';

import '../src/workspace/caps_test.dart' as caps;

void main() => caps.main();
