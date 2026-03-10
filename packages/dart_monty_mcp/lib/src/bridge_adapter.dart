import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Collects [BridgeEvent]s from a bridge execution stream and produces
/// a single MCP [CallToolResult].
///
/// Buffers stdout text from [BridgeTextContent] events. On
/// [BridgeRunFinished], returns success with captured output and return
/// value. On [BridgeRunError], returns an error result.
Future<CallToolResult> bridgeEventsToResult(
  Stream<BridgeEvent> events,
) async {
  final stdout = StringBuffer();

  await for (final event in events) {
    switch (event) {
      case BridgeTextContent(:final delta):
        stdout.write(delta);

      case BridgeRunFinished(:final value, :final printOutput):
        final parts = <String>[];
        _appendCapturedOutput(parts, stdout, printOutput);
        if (value != null) parts.add('$value');
        final text = parts.isEmpty ? '(no output)' : parts.join('\n');
        return CallToolResult(
          content: [TextContent(text: text)],
        );

      case BridgeRunError(:final message, :final printOutput):
        final parts = <String>[];
        _appendCapturedOutput(parts, stdout, printOutput);
        parts.add(message);
        return CallToolResult(
          isError: true,
          content: [TextContent(text: parts.join('\n'))],
        );

      default:
        break;
    }
  }

  return const CallToolResult(
    isError: true,
    content: [TextContent(text: 'Execution ended without result')],
  );
}

/// Appends captured stdout (or fallback [printOutput]) to [parts].
///
/// Prefers the bridge-buffered [stdout] over the platform's [printOutput]
/// because the bridge's print preamble intercepts Python's `print()`.
void _appendCapturedOutput(
  List<String> parts,
  StringBuffer stdout,
  String? printOutput,
) {
  final output = stdout.isNotEmpty ? stdout.toString() : printOutput;
  if (output != null && output.isNotEmpty) parts.add(output.trimRight());
}

/// Converts a [MontyResult] from a session execution to a [CallToolResult].
CallToolResult montyResultToCallToolResult(MontyResult result) {
  if (result.error != null) {
    final parts = <String>[];
    if (result.printOutput != null && result.printOutput!.isNotEmpty) {
      parts.add(result.printOutput!.trimRight());
    }
    parts.add(result.error!.message);
    return CallToolResult(
      isError: true,
      content: [TextContent(text: parts.join('\n'))],
    );
  }

  final parts = <String>[];
  if (result.printOutput != null && result.printOutput!.isNotEmpty) {
    parts.add(result.printOutput!.trimRight());
  }
  if (result.value != null) {
    parts.add('${result.value}');
  }
  final text = parts.isEmpty ? '(no output)' : parts.join('\n');
  return CallToolResult(content: [TextContent(text: text)]);
}
