// Harness for the published demo pages: discovery, a recording HTTP server,
// and a Chrome DevTools Protocol client.
//
// WHAT THIS EXISTS TO CATCH.
//
// `dart compile js` proves a demo COMPILES. `tool/check_pages_inputs.sh` proves
// every file the deploy copies EXISTS. Neither proves a demo RUNS, and this
// repo has already paid for the difference: async_matrix_demo.dart.js returned
// 404 on the live site while async_matrix.html returned 200, and the site sat
// stale from 2026-06-02 with every check green. A page that loads and a script
// that does not is exactly the failure GitHub Pages hides, because it keeps
// serving the last good build.
//
// So this harness serves the assembled site the way Pages does, drives a real
// headless Chrome at every published page, and fails on three things: no boot
// signal, an uncaught JS exception, or ANY same-origin request the server
// answered with 4xx/5xx.
//
// PRODUCTION-FAITHFUL: NO COOP/COEP HEADERS. GitHub Pages cannot set custom
// response headers, so a gate that sent them would be testing a configuration
// that never ships. Same reasoning as dart_monty_core/tool/check_pages.sh,
// which had to have them removed for that reason.
//
// THE SERVER IS THE NETWORK ORACLE, NOT CHROME. Chrome's stderr does not report
// failed subresource fetches at --v=0, and CDP's Network domain only sees the
// target it is attached to — which excludes the WASM worker that fetches
// dart_monty_core_native.wasm. The server sees every request from every
// context, so the 404 assertions are made against its own log.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One HTTP request answered by a [DemoServer], as it was answered.
class ServedRequest {
  /// Records that [path] was answered with [status].
  const ServedRequest(this.status, this.path);

  /// The status code the server returned.
  final int status;

  /// The request path, without query string.
  final String path;

  /// Whether the server could not answer this request.
  bool get failed => status >= 400;

  @override
  String toString() => '$status $path';
}

/// A static file server over the assembled demo site that RECORDS every
/// request it answers.
///
/// Deliberately hand-rolled on `dart:io` rather than pulled from a package:
/// the recording behaviour is the entire point, and it must see the requests
/// made by the WASM Worker as well as by the page.
class DemoServer {
  DemoServer._(this._server, this._root);

  final HttpServer _server;
  final String _root;

  /// Every request answered so far, oldest first.
  final List<ServedRequest> requests = <ServedRequest>[];

  /// The origin pages should be loaded from, e.g. `http://127.0.0.1:53124`.
  String get origin => 'http://127.0.0.1:${_server.port}';

  static const _contentTypes = <String, String>{
    '.css': 'text/css; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.map': 'application/json; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.svg': 'image/svg+xml',
    // REQUIRED, not cosmetic. The worker instantiates the engine with
    // WebAssembly.instantiateStreaming(), which REJECTS any response whose
    // Content-Type is not exactly application/wasm. Serving it as
    // text/plain fails the demo in a way that looks like an engine bug.
    '.wasm': 'application/wasm',
  };

  /// Binds a server on an ephemeral loopback port serving [root].
  static Future<DemoServer> bind(String root) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final demo = DemoServer._(server, p.canonicalize(root));
    unawaited(demo._accept());
    return demo;
  }

  /// Stops serving.
  Future<void> close() => _server.close(force: true);

  Future<void> _accept() async {
    await for (final request in _server) {
      // One bad request must not take the server down: Chrome cancels
      // in-flight fetches on navigation, which surfaces here as a write to a
      // closed socket. A server that dies there reports the NEXT page as
      // having 404'd everything.
      try {
        await _answer(request);
      } on Object catch (_) {
        // Already recorded; the socket is gone and there is nothing to say.
      }
    }
  }

  Future<void> _answer(HttpRequest request) async {
    final requestPath = request.uri.path;
    final relative = requestPath.endsWith('/')
        ? '${requestPath}index.html'
        : requestPath;
    final resolved = p.canonicalize(
      p.join(_root, relative.replaceFirst(RegExp('^/+'), '')),
    );
    final file = File(resolved);
    final found = p.isWithin(_root, resolved) && file.existsSync();
    final status = found ? HttpStatus.ok : HttpStatus.notFound;
    requests.add(ServedRequest(status, requestPath));

    final response = request.response..statusCode = status;
    if (found) {
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        _contentTypes[p.extension(resolved)] ?? 'application/octet-stream',
      );
      await response.addStream(file.openRead());
    } else {
      response.write('404 $requestPath');
    }
    await response.close();
  }
}

/// The outcome of running one selectable example on a demo page.
class ExampleRun {
  /// Records that [key] ran and produced [status] / [detail].
  const ExampleRun({
    required this.key,
    required this.ok,
    required this.status,
    required this.detail,
    required this.elapsed,
  });

  /// The `<option value>` that was selected.
  final String key;

  /// Whether THE PAGE rendered this run as a success.
  ///
  /// Read out of the page's own verdict — its status label and its error
  /// node — not out of the console. A demo that catches its own exception and
  /// paints it red has failed, and only the rendering knows that.
  final bool ok;

  /// The page's status label after the run, e.g. `Done` or `Error`.
  final String status;

  /// The rendered error, or the head of the rendered result.
  final String detail;

  /// How long the example took to run.
  final Duration elapsed;

  @override
  String toString() =>
      '$key: ${ok ? 'ok' : 'FAILED'} [$status] '
      '${elapsed.inMilliseconds}ms ${detail.replaceAll('\n', ' ')}';
}

/// Everything observed while one page was loaded.
class PageLoad {
  /// Records the outcome of loading [page].
  const PageLoad({
    required this.page,
    required this.url,
    required this.ready,
    required this.error,
    required this.exceptions,
    required this.consoleErrors,
    required this.elapsed,
    required this.hasExampleRunner,
    required this.exampleKeys,
    required this.examples,
  });

  /// The page path, e.g. `vfs.html`.
  final String page;

  /// The absolute URL that was loaded.
  final String url;

  /// The value of `window.__montyDemoReady`, or null if it never appeared.
  final String? ready;

  /// The value of `window.__montyDemoError`, if the demo declared failure.
  final String? error;

  /// Uncaught JS exceptions raised by the page.
  final List<String> exceptions;

  /// `console.error` calls and browser error log entries from the page.
  final List<String> consoleErrors;

  /// How long the page took to reach a signal, or to time out.
  final Duration elapsed;

  /// Whether the page exposes `window.__montyRunExample`.
  final bool hasExampleRunner;

  /// The `<option value>` keys discovered in the live DOM, in document order.
  ///
  /// DISCOVERED AT RUNTIME, never hardcoded: an example added to the page is
  /// covered by the next run, and a selector that silently stops matching
  /// produces an empty list that the suite refuses.
  final List<String> exampleKeys;

  /// One entry per example that was driven, in the order they ran.
  final List<ExampleRun> examples;

  /// A multi-line description of why this load is not a pass.
  String describe() {
    final buffer = StringBuffer()
      ..writeln('page:        $page ($url)')
      ..writeln('ready:       ${ready ?? '<never signalled>'}')
      ..writeln('demo error:  ${error ?? '<none>'}')
      ..writeln('elapsed:     ${elapsed.inMilliseconds}ms');
    for (final e in exceptions) {
      buffer.writeln('exception:   $e');
    }
    for (final e in consoleErrors) {
      buffer.writeln('console err: $e');
    }
    for (final e in examples.where((e) => !e.ok)) {
      buffer.writeln('example:     $e');
    }
    return buffer.toString();
  }
}

/// Reads the example dropdown out of the LIVE DOM of a demo page.
///
/// Every `<option value>` that is not the empty placeholder is an example the
/// page offers, so this is the set the gate must run. Written as one JS
/// expression rather than assembled in Dart so that what runs in the browser
/// is readable as JavaScript.
const _discoverExamplesJs = '''
JSON.stringify({
  hasRunner: typeof window.__montyRunExample === 'function',
  keys: Array.from(document.querySelectorAll('select option[value]'))
          .map(o => o.value)
          .filter(v => v !== '')
})''';

/// A minimal Chrome DevTools Protocol client over `dart:io`.
///
/// WHY NOT puppeteer / node. dart_monty_core drives its Pages gate with
/// `node tool/pages_drive.mjs`, which needs Node >= 22 for a global WebSocket
/// — and that is a runtime this repo's CI does not otherwise install or pin.
/// `dart:io` ships a WebSocket and an HttpServer, so the whole harness runs on
/// the SDK the rest of the gate already requires. No new dependency, and
/// nothing to keep in step with a second language's toolchain.
///
/// WHY NOT chrome-devtools-mcp: it holds one shared browser profile and
/// refuses to attach when an instance is already running, which makes it
/// unusable unattended. This uses its own throwaway profile every time.
class Chrome {
  Chrome._(this._process, this._socket, this._profile) {
    _socket.listen(
      _onMessage,
      onDone: () => _closed = true,
      onError: (Object _) => _closed = true,
    );
  }

  final Process _process;
  final WebSocket _socket;
  final Directory _profile;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  int _nextId = 0;
  bool _closed = false;

  /// Executables to try, in order, when `CHROME_EXECUTABLE` is not set.
  static const _candidates = <String>[
    'google-chrome-stable',
    'google-chrome',
    'chromium',
    'chromium-browser',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ];

  /// Finds a Chrome/Chromium binary, or returns null.
  ///
  /// Returning null rather than throwing is deliberate: a missing browser is a
  /// reason for the gate to SKIP VISIBLY (exit 77), never to pass quietly.
  static String? locate() {
    final configured = Platform.environment['CHROME_EXECUTABLE'];
    if (configured != null && configured.isNotEmpty) {
      if (File(configured).existsSync()) return configured;
    }
    for (final candidate in _candidates) {
      if (candidate.startsWith('/')) {
        if (File(candidate).existsSync()) return candidate;
        continue;
      }
      final which = Process.runSync('which', <String>[candidate]);
      if (which.exitCode == 0) {
        final path = (which.stdout as String).trim();
        if (path.isNotEmpty) return path;
      }
    }
    return null;
  }

  /// Launches [executable] headless with a throwaway profile and attaches.
  static Future<Chrome> launch(String executable) async {
    final profile = Directory.systemTemp.createTempSync('monty-demo-chrome-');
    final process = await Process.start(executable, <String>[
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      // Ephemeral: a fixed port collides with a developer's own Chrome and
      // with a second copy of this gate. Chrome writes the port it chose
      // into DevToolsActivePort under the profile directory.
      '--remote-debugging-port=0',
      '--user-data-dir=${profile.path}',
      'about:blank',
    ]);
    // Drain both pipes. Chrome is chatty on stderr (dbus, GPU) and a full
    // pipe wedges the process with no error anywhere.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final portFile = File(p.join(profile.path, 'DevToolsActivePort'));
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (portFile.existsSync()) {
        final lines = portFile.readAsLinesSync();
        if (lines.length >= 2 && int.tryParse(lines[0]) != null) {
          final socket = await WebSocket.connect(
            'ws://127.0.0.1:${lines[0]}${lines[1]}',
          );
          return Chrome._(process, socket, profile);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    process.kill(ProcessSignal.sigkill);
    throw StateError(
      'Chrome ($executable) never wrote DevToolsActivePort under '
      '${profile.path} — it did not start.',
    );
  }

  /// Shuts the browser down and removes its profile.
  Future<void> close() async {
    await _socket.close();
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
    try {
      _profile.deleteSync(recursive: true);
    } on FileSystemException catch (_) {
      // A leftover temp profile is noise, not a failure.
    }
    await _events.close();
  }

  /// Sends one CDP command and waits for its reply.
  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic>? params,
    String? sessionId,
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (_closed) throw StateError('CDP socket closed before $method');
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode(<String, dynamic>{
        'id': id,
        'method': method,
        'params': params ?? const <String, dynamic>{},
        'sessionId': ?sessionId,
      }),
    );
    return completer.future.timeout(timeout);
  }

  void _onMessage(dynamic raw) {
    final message = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = message['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = message['error'];
      if (error != null) {
        completer.completeError(StateError('CDP error: ${jsonEncode(error)}'));
      } else {
        completer.complete(
          (message['result'] as Map<String, dynamic>?) ??
              const <String, dynamic>{},
        );
      }
      return;
    }
    _events.add(message);
  }

  /// Loads [url] in a fresh tab and waits for its boot signal.
  ///
  /// Waits on `window.__montyDemoReady` / `window.__montyDemoError` by polling
  /// — an explicit condition the page raises, never a fixed sleep. A demo that
  /// gets slower stays green; a demo that stops booting goes red at [timeout]
  /// with everything the browser said about it.
  Future<PageLoad> load(
    String page,
    String url, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final stopwatch = Stopwatch()..start();
    final created = await send(
      'Target.createTarget',
      params: <String, dynamic>{'url': 'about:blank'},
    );
    final targetId = created['targetId'] as String;
    final attached = await send(
      'Target.attachToTarget',
      params: <String, dynamic>{'targetId': targetId, 'flatten': true},
    );
    final sessionId = attached['sessionId'] as String;

    final exceptions = <String>[];
    final consoleErrors = <String>[];
    final subscription = _events.stream.listen((message) {
      if (message['sessionId'] != sessionId) return;
      final params =
          (message['params'] as Map<String, dynamic>?) ??
          const <String, dynamic>{};
      switch (message['method']) {
        case 'Runtime.exceptionThrown':
          final details =
              (params['exceptionDetails'] as Map<String, dynamic>?) ??
              const <String, dynamic>{};
          final exception = details['exception'] as Map<String, dynamic>?;
          exceptions.add(
            '${details['text']} ${exception?['description'] ?? ''}'.trim(),
          );
        case 'Runtime.consoleAPICalled':
          if (params['type'] != 'error') return;
          final args = (params['args'] as List<dynamic>? ?? const <dynamic>[])
              .map(
                (a) =>
                    (a as Map<String, dynamic>)['value'] ??
                    a['description'] ??
                    '',
              )
              .join(' ');
          consoleErrors.add('console.error: $args');
        case 'Log.entryAdded':
          final entry =
              (params['entry'] as Map<String, dynamic>?) ??
              const <String, dynamic>{};
          if (entry['level'] != 'error') return;
          // The unprompted favicon probe is noise: every browser makes it and
          // no published page references one.
          final source = '${entry['url'] ?? ''}';
          if (source.endsWith('/favicon.ico')) return;
          consoleErrors.add('log(${entry['source']}): ${entry['text']}');
      }
    });

    String? ready;
    String? error;
    var hasRunner = false;
    final exampleKeys = <String>[];
    final examples = <ExampleRun>[];
    try {
      await send('Runtime.enable', sessionId: sessionId);
      await send('Log.enable', sessionId: sessionId);
      await send('Page.enable', sessionId: sessionId);
      await send(
        'Page.navigate',
        params: <String, dynamic>{'url': url},
        sessionId: sessionId,
      );

      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final probe = await _probeSignals(sessionId);
        ready = probe?['ready'] as String?;
        error = probe?['error'] as String?;
        if (ready != null || error != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // A PAGE THAT BOOTS IS NOT A PAGE THAT WORKS.
      //
      // agent.html and vfs.html each carry a dropdown of self-contained
      // examples; the page can come up clean while one of those examples is
      // broken. So once the page is ready, every example it offers is SELECTED
      // AND RUN through the page's own UI, and the page's own rendering of the
      // outcome is what counts.
      if (ready != null && error == null) {
        final discovered = await _discoverExamples(sessionId);
        hasRunner = discovered.hasRunner;
        exampleKeys.addAll(discovered.keys);
        if (hasRunner) {
          for (final key in exampleKeys) {
            examples.add(await _runExample(sessionId, key));
          }
        }
      }
    } finally {
      // Give any error the page raised in its last instant a chance to be
      // delivered before the listener is torn down.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await subscription.cancel();
      await send(
        'Target.closeTarget',
        params: <String, dynamic>{'targetId': targetId},
      );
      stopwatch.stop();
    }

    return PageLoad(
      page: page,
      url: url,
      ready: ready,
      error: error,
      exceptions: exceptions,
      consoleErrors: consoleErrors,
      elapsed: stopwatch.elapsed,
      hasExampleRunner: hasRunner,
      exampleKeys: exampleKeys,
      examples: examples,
    );
  }

  Future<({bool hasRunner, List<String> keys})> _discoverExamples(
    String sessionId,
  ) async {
    // READ THE LIVE DOM, not the source file: an example added by script is
    // as published as one written into the HTML, and the gate must see both.
    // The test cross-checks this against a static parse of the page source, so
    // a selector that stops matching cannot quietly reduce coverage.
    final value = await _evaluateString(
      sessionId,
      _discoverExamplesJs,
    );
    if (value == null) return (hasRunner: false, keys: const <String>[]);
    final decoded = jsonDecode(value) as Map<String, dynamic>;
    final keys = <String>[];
    for (final key in decoded['keys'] as List<dynamic>) {
      final text = key as String;
      if (!keys.contains(text)) keys.add(text);
    }
    return (hasRunner: decoded['hasRunner'] as bool, keys: keys);
  }

  Future<ExampleRun> _runExample(String sessionId, String key) async {
    final stopwatch = Stopwatch()..start();
    // A HUNG EXAMPLE MUST NOT HANG THE GATE. Every example observed so far
    // finishes well inside a second; 120s is the point past which "slow" and
    // "wedged" stop being worth distinguishing, and a wedged one is reported
    // as a failure with its key rather than as a dead suite.
    String? value;
    try {
      value = await _evaluateString(
        sessionId,
        'window.__montyRunExample(${jsonEncode(key)})',
        awaitPromise: true,
        timeout: const Duration(seconds: 120),
      );
    } on Object catch (e) {
      stopwatch.stop();
      return ExampleRun(
        key: key,
        ok: false,
        status: 'driver-error',
        detail: '$e',
        elapsed: stopwatch.elapsed,
      );
    }
    stopwatch.stop();
    if (value == null) {
      return ExampleRun(
        key: key,
        ok: false,
        status: 'no-verdict',
        detail: 'window.__montyRunExample returned nothing',
        elapsed: stopwatch.elapsed,
      );
    }
    final decoded = jsonDecode(value) as Map<String, dynamic>;
    return ExampleRun(
      key: key,
      ok: decoded['ok'] as bool,
      status: '${decoded['status']}',
      detail: '${decoded['detail']}',
      elapsed: stopwatch.elapsed,
    );
  }

  Future<String?> _evaluateString(
    String sessionId,
    String expression, {
    bool awaitPromise = false,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final result = await send(
      'Runtime.evaluate',
      params: <String, dynamic>{
        'expression': expression,
        'returnByValue': true,
        'awaitPromise': awaitPromise,
      },
      sessionId: sessionId,
      timeout: timeout,
    );
    final details = result['exceptionDetails'];
    if (details != null) {
      throw StateError('evaluate threw: ${jsonEncode(details)}');
    }
    return (result['result'] as Map<String, dynamic>?)?['value'] as String?;
  }

  Future<Map<String, dynamic>?> _probeSignals(String sessionId) async {
    // A page that reloads itself (coi-serviceworker does, once, when the
    // origin is not cross-origin isolated) destroys the execution context
    // mid-probe. That is a transient, not a failure — poll again.
    try {
      final value = await _evaluateString(
        sessionId,
        'JSON.stringify({ready: window.__montyDemoReady ?? null, '
        'error: window.__montyDemoError ?? null})',
      );
      if (value == null) return null;
      return jsonDecode(value) as Map<String, dynamic>;
    } on Object catch (_) {
      return null;
    }
  }
}

/// Lists the tracked files matching [pattern], refusing an empty match.
///
/// DISCOVERED, NOT ENUMERATED — the same rule as
/// `tool/check_page_versions.sh`, and for the same reason: its predecessor
/// listed two files by name and so could not see that seven of the eight
/// published pages were unversioned. A gate whose subject list is hand-written
/// stops covering the thing it names the moment someone adds a file.
///
/// A glob that matches nothing is a FAILURE, never an empty pass: that is how
/// a rename turns a gate into a no-op that still reports success.
List<String> trackedFiles(String pattern) {
  final result = Process.runSync('git', <String>['ls-files', pattern]);
  if (result.exitCode != 0) {
    throw StateError(
      'git ls-files $pattern failed (${result.exitCode}): ${result.stderr}',
    );
  }
  final files =
      (result.stdout as String)
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList()
        ..sort();
  if (files.isEmpty) {
    throw StateError(
      "git ls-files '$pattern' matched nothing. A glob that stopped matching "
      'would make this gate verify nothing at all, so it fails instead.',
    );
  }
  return files;
}

/// The `*.dart.js` bundles a published page loads, in document order.
///
/// This is what ties the two discovered sets together: every entrypoint under
/// `example/web/bin/` must be named by at least one page, or it is a demo that
/// only ever gets compiled and never gets run — which is the state all seven
/// were in before this gate existed.
List<String> scriptsLoadedBy(String pageFile) {
  final html = File(pageFile).readAsStringSync();
  return RegExp(
    r'''src=["']([A-Za-z0-9_]+\.dart\.js)["']''',
  ).allMatches(html).map((m) => m.group(1)!).toSet().toList()..sort();
}

/// The example keys a published page declares in its source, in document
/// order and de-duplicated.
///
/// Parsed statically so the SUITE SHAPE is known before a browser starts: one
/// test per example, and a floor that rises the moment an example is added.
/// The page-boot test cross-checks this against what the live DOM offers, so
/// the two can never drift apart silently.
///
/// The empty placeholder option (`<option value="">Load example...</option>`)
/// is not an example and is excluded.
List<String> exampleKeysIn(String pageFile) =>
    exampleKeysInHtml(File(pageFile).readAsStringSync());

/// [exampleKeysIn] over an in-memory document.
///
/// SCRIPT AND COMMENT BODIES ARE STRIPPED FIRST, and that is not a nicety.
/// Measured while falsifying this gate: a `<option value="brandnew">` written
/// inside a JS COMMENT in vfs.html and agent.html — documentation of this very
/// check — was counted as two real examples, and the floor rose to 32 for a
/// page set that offers 30. A parser that reads markup out of a comment
/// invents subjects that cannot be run.
///
/// The live-DOM discovery in the harness is the authority; this static parse
/// exists so the suite shape is known before a browser starts, and the two are
/// asserted equal, so any remaining disagreement fails rather than guesses.
List<String> exampleKeysInHtml(String html) {
  final markup = html
      .replaceAll(
        RegExp(
          r'<script\b[^>]*>.*?</script>',
          dotAll: true,
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp('<!--.*?-->', dotAll: true), '');
  final keys = <String>[];
  for (final match in RegExp(
    r'''<option[^>]*\svalue=["']([^"']*)["']''',
  ).allMatches(markup)) {
    final key = match.group(1)!;
    if (key.isEmpty || keys.contains(key)) continue;
    keys.add(key);
  }
  return keys;
}
