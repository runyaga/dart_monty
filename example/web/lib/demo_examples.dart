import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Loads the single source of published Python snippets.
Future<Map<String, Map<String, dynamic>>> loadDemoExamples() async {
  final response = await web.window.fetch('examples.json'.toJS).toDart;
  if (!response.ok) throw StateError('Could not load examples.json');
  final data = jsonDecode((await response.text().toDart).toDart) as List;
  return {
    for (final item in data.cast<Map<String, dynamic>>())
      item['id'] as String: item,
  };
}
