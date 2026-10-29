import 'package:web_example/bridge_walkthrough.dart';
import 'package:web_example/demo_ready.dart';
import 'package:web_example/runtime_page.dart';

Future<void> main() async {
  try {
    await runBridgeWalkthrough();
    await startRuntimePage('main');
  } on Object catch (e) {
    montyDemoFailed('main', 'Bridge walkthrough failed: $e');
  }
}
