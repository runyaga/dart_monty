// Standalone JS-compiled demo, not a package:test file.
// ignore_for_file: avoid_print, use_null_aware_elements
/// Interactive Reactive UI Demo — shows SDUI and Daemon Mode.
///
/// Compiled to JS, exposes functions to the HTML UI via window.ReactiveDemo.
///
/// Build:
///   dart compile js example/web/bin/reactive_demo.dart \
///     -o example/web/web/reactive_demo.dart.js
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

// ---------------------------------------------------------------------------
// JS interop — expose API to HTML
// ---------------------------------------------------------------------------

@JS('window.ReactiveDemo')
external set _reactiveDemo(JSObject obj);

@JS('onRender')
external JSFunction? get onJsRender;

@JS('onSetState')
external JSFunction? get onJsSetState;

@JS('window._onEvent')
external void _jsOnEvent(JSString jsonPayload);

@JS('window._onReady')
external void _jsOnReady();

@JS('document.getElementById')
external JSObject? _getElementById(JSString id);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

ReplSession? _session;
bool _initialized = false;
VanillaUiPlugin? _uiPlugin;

// ---------------------------------------------------------------------------
// The VanillaUiPlugin
// ---------------------------------------------------------------------------

class VanillaUiPlugin extends MontyPlugin {
  Completer<Map<String, Object?>>? _pendingEvent;

  @override
  String get namespace => 'ui';

  @override
  List<HostFunction> get functions => [
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'ui_render',
            description: 'Render UI tree.',
            params: [
              HostParam(name: 'tree', type: HostParamType.map, description: 'JSON tree'),
            ],
          ),
          handler: (args) async {
            final tree = args['tree'] as Map;
            final treeJson = jsonEncode(tree);
            if (onJsRender != null) {
              onJsRender!.callAsFunction(null, treeJson.toJS);
            } else {
              _renderToContainer(tree);
            }
            return null;
          },
        ),
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'ui_set_state',
            description: 'Update UI state.',
            params: [
              HostParam(name: 'id', type: HostParamType.string, description: 'Element ID'),
              HostParam(name: 'prop', type: HostParamType.string, description: 'Property'),
              HostParam(name: 'value', type: HostParamType.any, description: 'Value'),
            ],
          ),
          handler: (args) async {
            final id = args['id']?.toString() ?? '';
            final prop = args['prop']?.toString() ?? '';
            final value = args['value'];
            
            if (onJsSetState != null) {
              onJsSetState!.callAsFunction(null, id.toJS, prop.toJS, value?.toString().toJS);
            } else {
              _updateDomNode(id, prop, value);
            }
            return null;
          },
        ),
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'ui_wait_for_event',
            description: 'Wait for UI event.',
            params: [],
          ),
          handler: (_) async {
            final completer = Completer<Map<String, Object?>>();
            _pendingEvent = completer;
            return await completer.future;
          },
        ),
      ];

  void dispatchUiEvent(String elementId, String action, Map<String, Object?> payload) {
    if (_pendingEvent != null) {
      _pendingEvent!.complete({
        'id': elementId,
        'action': action,
        'payload': payload,
      });
      _pendingEvent = null;
    }
  }

  // JS Interop Helpers for DOM Manipulation

  void _renderToContainer(Map tree) {
    final container = _getElementById('app-canvas'.toJS);
    if (container == null) return;
    
    // Clear container
    container.setProperty('innerHTML'.toJS, ''.toJS);
    
    final element = _createDomNode(tree);
    if (element != null) {
      container.callMethod('appendChild'.toJS, element);
    }
  }

  JSObject? _createDomNode(Map node) {
    final type = node['type'] as String?;
    if (type == null) return null;

    final document = _getElementById('app-canvas'.toJS)?.getProperty('ownerDocument'.toJS) as JSObject?;
    if (document == null) return null;

    String tag;
    switch (type) {
      case 'col': tag = 'div'; break;
      case 'text': tag = 'span'; break;
      case 'button': tag = 'button'; break;
      case 'input': tag = 'input'; break;
      default: tag = 'div';
    }

    final element = document.callMethod('createElement'.toJS, tag.toJS) as JSObject;

    if (type == 'col') {
      final style = element.getProperty('style'.toJS) as JSObject;
      style.setProperty('display'.toJS, 'flex'.toJS);
      style.setProperty('flexDirection'.toJS, 'column'.toJS);
      style.setProperty('gap'.toJS, '8px'.toJS);
    }

    if (node['id'] != null) {
      element.setProperty('id'.toJS, (node['id'] as String).toJS);
    }

    if (type == 'text' && node['value'] != null) {
      element.setProperty('innerText'.toJS, (node['value'] as String).toJS);
      if (node['color'] != null) {
        (element.getProperty('style'.toJS) as JSObject).setProperty('color'.toJS, (node['color'] as String).toJS);
      }
    }

    if (type == 'input') {
      if (node['placeholder'] != null) {
        element.setProperty('placeholder'.toJS, (node['placeholder'] as String).toJS);
      }
      element.setProperty('className'.toJS, 'ui-input'.toJS);
    }

    if (type == 'button') {
      element.setProperty('innerText'.toJS, (node['label'] as String? ?? '').toJS);
      element.setProperty('className'.toJS, 'btn btn-ui'.toJS);
      if (node['action'] != null) {
        final action = node['action'] as String;
        final id = node['id'] as String? ?? '';
        final clickHandler = ((JSAny e) {
          final payload = <String, Object?>{};
          // If there's an input with id 'name_input', let's grab it for demo purposes
          final nameInput = _getElementById('name_input'.toJS);
          if (nameInput != null) {
            payload['name_input'] = (nameInput.getProperty('value'.toJS) as JSString).toDart;
          }
          final queryInput = _getElementById('query_input'.toJS);
          if (queryInput != null) {
            payload['query_input'] = (queryInput.getProperty('value'.toJS) as JSString).toDart;
          }
          dispatchUiEvent(id, action, payload);
        }).toJS;
        element.callMethod('addEventListener'.toJS, 'click'.toJS, clickHandler);
      }
    }

    if (node['children'] != null) {
      final children = node['children'] as List;
      for (final child in children) {
        if (child is Map) {
          final childElement = _createDomNode(child);
          if (childElement != null) {
            element.callMethod('appendChild'.toJS, childElement);
          }
        }
      }
    }

    return element;
  }

  void _updateDomNode(String id, String prop, Object? value) {
    final element = _getElementById(id.toJS);
    if (element == null) return;

    if (prop == 'value' && element.getProperty('tagName'.toJS) == 'SPAN'.toJS) {
      element.setProperty('innerText'.toJS, (value?.toString() ?? '').toJS);
    } else if (prop == 'disabled') {
      element.setProperty('disabled'.toJS, (value == true).toJS);
    } else if (prop == 'color') {
      (element.getProperty('style'.toJS) as JSObject).setProperty('color'.toJS, (value?.toString() ?? '').toJS);
    } else {
      element.setProperty(prop.toJS, (value?.toString() ?? '').toJS);
    }
  }
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

Future<String?> _init() async {
  if (_initialized) return null;

  try {
    _uiPlugin = VanillaUiPlugin();
    final plugins = <MontyPlugin>[
      _uiPlugin!,
      // Simulated HTTP fetch for the LLM demo
      HostFunctionPlugin(
        namespace: 'http',
        functions: [
          HostFunction(
            schema: const HostFunctionSchema(name: 'http_get', description: 'Mock fetch', params: [HostParam(name: 'q', type: HostParamType.string, description: 'Query')]),
            handler: (args) async {
              await Future.delayed(const Duration(seconds: 1));
              return 'Results for "${args['q']}": Found 42 items.';
            },
          ),
        ],
      )
    ];

    _session = ReplSession(plugins: plugins, os: OsProvider.compose({}));

    _initialized = true;
    return null;
  } catch (e, st) {
    print('Init failed: $e\n$st');
    return e.toString();
  }
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

Future<String> _apiInit() async {
  final error = await _init();
  if (error == null) {
    return jsonEncode({'ok': true});
  } else {
    return jsonEncode({'ok': false, 'error': error});
  }
}

Future<String> _apiRun(String code) async {
  if (!_initialized) {
    print('[_apiRun] Error: Not initialized');
    return jsonEncode({'ok': false, 'error': 'Not initialized'});
  }

  try {
    print('[_apiRun] Executing Python code:\n$code');
    // Clear container before run
    final container = _getElementById('app-canvas'.toJS);
    if (container != null) {
      container.setProperty('innerHTML'.toJS, ''.toJS);
    }

    final result = await _session!.run(code);
    print('[_apiRun] Execution complete. Success: ${!result.isError}');
    return jsonEncode(_resultToJson(result));
  } catch (e, st) {
    print('[_apiRun] Uncaught infrastructure error: $e\n$st');
    return jsonEncode({'ok': false, 'error': e.toString()});
  }
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _resultToJson(MontyResult result) {
  if (result.isError) {
    return {
      'ok': false,
      'error': result.error?.message ?? 'Unknown error',
      'excType': result.error?.excType,
      'print_output': result.printOutput,
    };
  }
  return {
    'ok': true,
    'value': result.value?.dartValue,
    'print_output': result.printOutput,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('[ReactiveDemo] Starting...');

  // Expose API to window
  final api = <String, JSFunction>{
    'init': (() => _apiInit().then((r) => r.toJS).toJS).toJS,
    'run': ((JSString code) => _apiRun(code.toDart).then((r) => r.toJS).toJS).toJS,
  }.jsify();
  _reactiveDemo = api as JSObject;

  print('[ReactiveDemo] API exposed on window.ReactiveDemo');

  // Signal ready
  try {
    _jsOnReady();
  } catch (_) {}
}

class HostFunctionPlugin extends MontyPlugin {
  HostFunctionPlugin({required this.namespace, required this.functions});
  @override
  final String namespace;
  @override
  final List<HostFunction> functions;
}
