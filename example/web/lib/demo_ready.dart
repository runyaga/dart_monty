/// The boot signal every published demo page raises for the headless gate.
///
/// WHY A SIGNAL AT ALL, AND WHY A UNIFORM ONE.
///
/// `dart compile js` proves a demo COMPILES. It says nothing about whether the
/// compiled program runs: the page can 404 its own `.dart.js`, the WASM worker
/// can fail to boot, `main()` can throw on the first line. This repo has
/// already paid for exactly that — `async_matrix_demo.dart.js` returned 404 on
/// the live site while `async_matrix.html` returned 200, and every check was
/// green.
///
/// Before this file each demo announced itself differently: `EXAMPLE_DONE` on
/// the console, a `window.VfsDemo` global, a `_onReady()` callback into the
/// page, or — for `visualizer.dart` — nothing observable at all. A gate built
/// on seven bespoke conditions is a gate that enumerates, and enumeration is
/// how an eighth demo gets added with no coverage and nobody notices.
///
/// So: ONE contract. Every entrypoint calls [montyDemoReady] once it has
/// finished booting, and [montyDemoFailed] if it cannot. The gate
/// (`tool/check_demo_pages.sh`) waits on `window.__montyDemoReady` and fails
/// on `window.__montyDemoError` — it does not need to know which demo it is
/// looking at. Adding a ninth demo that never calls [montyDemoReady] fails the
/// gate, which is the point.
///
/// NOT A SLEEP, AND NOT A HEURISTIC. The gate polls this global rather than
/// waiting a fixed interval, so a demo that gets slower stays green and a demo
/// that stops booting goes red immediately instead of intermittently.
library;

import 'dart:js_interop';

@JS('window.__montyDemoReady')
external set _readySignal(JSString value);

@JS('window.__montyDemoError')
external set _errorSignal(JSString value);

/// Announces that the demo named [demo] has finished booting.
///
/// Call this at the point where the demo is genuinely usable — after the WASM
/// bridge has initialised, or after an auto-running demo has completed its
/// workload — never merely at the top of `main()`. The whole value of the
/// signal is that reaching it required the demo to actually work.
void montyDemoReady(String demo) {
  _readySignal = demo.toJS;
}

/// Announces that the demo named [demo] could not boot, because of [reason].
///
/// This exists so a broken demo fails the gate in a second with a stated cause
/// rather than in two minutes with "timed out waiting for a ready signal".
void montyDemoFailed(String demo, String reason) {
  _errorSignal = '$demo: $reason'.toJS;
}
