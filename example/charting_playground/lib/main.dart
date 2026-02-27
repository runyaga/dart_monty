import 'dart:async';
import 'dart:convert';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';
import 'package:flutter/material.dart';

import 'chart_builder.dart';
import 'df_registry.dart';
import 'dispatch.dart';
import 'examples.dart';

// VS Code dark palette — matches the other dart_monty examples.
const _kBg = Color(0xFF1E1E1E);
const _kSurface = Color(0xFF252526);
const _kBorder = Color(0xFF404040);
const _kText = Color(0xFFD4D4D4);
const _kMuted = Color(0xFF808080);
const _kBlue = Color(0xFF569CD6);
const _kYellow = Color(0xFFDCDCAA);
const _kGreen = Color(0xFF6A9955);
const _kRed = Color(0xFFF44747);
const _kOrange = Color(0xFFCE9178);

void main() {
  runApp(const ChartingPlaygroundApp());
}

/// Root widget.
class ChartingPlaygroundApp extends StatelessWidget {
  /// Creates a [ChartingPlaygroundApp].
  const ChartingPlaygroundApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Charting Playground',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _kBg,
        colorScheme: const ColorScheme.dark(
          primary: _kBlue,
          secondary: _kYellow,
          surface: _kSurface,
          onSurface: _kText,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _kSurface,
          foregroundColor: _kText,
          elevation: 0,
        ),
        dividerColor: _kBorder,
      ),
      home: const _PlaygroundPage(),
    );
  }
}

class _PlaygroundPage extends StatefulWidget {
  const _PlaygroundPage();

  @override
  State<_PlaygroundPage> createState() => _PlaygroundPageState();
}

class _PlaygroundPageState extends State<_PlaygroundPage> {
  final _codeController = TextEditingController(
    text: examples.first.code,
  );
  final _logLines = <_LogEntry>[];
  final _scrollController = ScrollController();

  final _dfRegistry = DfRegistry();
  final _chartBuilder = ChartBuilder();

  MontyPlatform? _monty;
  bool _running = false;
  bool _initialized = false;
  String _status = 'Initializing WASM...';
  Color _statusColor = _kBlue;
  String _selectedExample = examples.first.name;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final monty = MontyWasm(bindings: WasmBindingsJs());
      _monty = monty;
      setState(() {
        _initialized = true;
        _status = 'Ready';
        _statusColor = _kGreen;
      });
    } on Object catch (e) {
      setState(() {
        _status = 'Init failed: $e';
        _statusColor = _kRed;
      });
    }
  }

  void _log(String text, {Color color = _kText}) {
    setState(() {
      _logLines.add(_LogEntry(text, color));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
          _scrollController.position.maxScrollExtent,
        );
      }
    });
  }

  Future<void> _run() async {
    if (_running || !_initialized || _monty == null) return;

    setState(() {
      _running = true;
      _status = 'Running...';
      _statusColor = _kYellow;
      _logLines.clear();
      _dfRegistry.disposeAll();
      _chartBuilder.clear();
    });

    final code = _codeController.text;
    _log('>>> Running Python code', color: _kMuted);

    // Dispose previous and create fresh instance
    await _monty?.dispose();
    final monty = MontyWasm(bindings: WasmBindingsJs());
    _monty = monty;

    try {
      var progress = await monty.start(
        code,
        externalFunctions: allExternalFunctions,
      );

      while (progress is MontyPending) {
        final pending = progress;
        _log(
          '  ${pending.functionName}'
          '(${_formatArgs(pending.arguments)})',
          color: _kOrange,
        );

        try {
          // Debug: log arg types for the first df_create call
          if (pending.functionName == 'df_create' &&
              pending.arguments.isNotEmpty) {
            final arg0 = pending.arguments[0];
            _log(
              '  [debug] arg0 type: ${arg0.runtimeType}',
              color: _kMuted,
            );
            if (arg0 is List && arg0.isNotEmpty) {
              _log(
                '  [debug] first element type: '
                '${arg0.first.runtimeType}',
                color: _kMuted,
              );
              if (arg0.first is Map) {
                final m = arg0.first as Map;
                for (final e in m.entries) {
                  _log(
                    '  [debug] key=${e.key} '
                    '(${e.key.runtimeType}), '
                    'val=${e.value} '
                    '(${e.value.runtimeType})',
                    color: _kMuted,
                  );
                }
              }
            }
          }

          final result = dispatch(
            pending,
            _dfRegistry,
            _chartBuilder,
          );

          // Force UI update after chart changes
          if (pending.functionName.startsWith('chart_')) {
            setState(() {});
          }

          _log('  → ${_formatResult(result)}', color: _kGreen);
          progress = await monty.resume(result);
        } on Object catch (e, st) {
          _log('  → Error: $e', color: _kRed);
          _log('  $st', color: _kMuted);
          progress = await monty.resumeWithError(e.toString());
        }
      }

      if (progress is MontyComplete) {
        final result = progress.result;
        if (result.isError) {
          _log(
            'Error: ${result.error!.message}',
            color: _kRed,
          );
          if (result.error!.lineNumber != null) {
            _log(
              '  at line ${result.error!.lineNumber}',
              color: _kMuted,
            );
          }
        } else {
          if (result.printOutput != null &&
              result.printOutput!.isNotEmpty) {
            _log('print: ${result.printOutput}', color: _kGreen);
          }
          _log(
            'Result: ${_formatResult(result.value)}',
            color: _kBlue,
          );
        }
        _log(
          'Usage: '
          'mem=${result.usage.memoryBytesUsed}B, '
          'time=${result.usage.timeElapsedMs}ms, '
          'stack=${result.usage.stackDepthUsed}',
          color: _kMuted,
        );
      }
    } on Object catch (e) {
      _log('Exception: $e', color: _kRed);
    }

    setState(() {
      _running = false;
      _status = 'Ready';
      _statusColor = _kGreen;
    });
  }

  String _formatArgs(List<Object?> args) {
    return args.map(_formatResult).join(', ');
  }

  String _formatResult(Object? value) {
    if (value == null) return 'null';
    if (value is String) {
      return value.length > 80
          ? '"${value.substring(0, 77)}..."'
          : '"$value"';
    }
    if (value is Map || value is List) {
      final json = jsonEncode(value);
      return json.length > 80 ? '${json.substring(0, 77)}...' : json;
    }
    return value.toString();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _scrollController.dispose();
    unawaited(_monty?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Charting Playground'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                'Python + Cristalyse + DataFrame',
                style: TextStyle(
                  color: _kMuted,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF2D2D2D),
              border: Border(
                left: BorderSide(color: _statusColor, width: 3),
                bottom: const BorderSide(color: _kBorder),
              ),
            ),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          // Main content
          Expanded(
            child: Row(
              children: [
                // Left panel: code editor
                Expanded(
                  flex: 2,
                  child: _buildCodePanel(),
                ),
                const VerticalDivider(width: 1),
                // Right panel: chart display
                Expanded(
                  flex: 3,
                  child: _buildChartPanel(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Bottom: log output
          SizedBox(
            height: 200,
            child: _buildLogPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildCodePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Example selector + Run button
        Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
            color: _kSurface,
            border: Border(bottom: BorderSide(color: _kBorder)),
          ),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  value: _selectedExample,
                  isExpanded: true,
                  dropdownColor: _kSurface,
                  style: const TextStyle(
                    color: _kText,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  items: examples
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.name,
                          child: Text(
                            e.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _running
                      ? null
                      : (name) {
                          if (name == null) return;
                          final ex = examples.firstWhere(
                            (e) => e.name == name,
                          );
                          setState(() {
                            _selectedExample = name;
                            _codeController.text = ex.code;
                          });
                        },
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed:
                    _running || !_initialized ? null : _run,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: _kBg,
                  disabledBackgroundColor: _kBorder,
                ),
              ),
            ],
          ),
        ),
        // Code editor
        Expanded(
          child: Container(
            color: _kBg,
            child: TextField(
              controller: _codeController,
              maxLines: null,
              expands: true,
              readOnly: _running,
              style: const TextStyle(
                fontFamily: 'Consolas, Monaco, monospace',
                fontSize: 13,
                height: 1.5,
                color: _kText,
              ),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.all(12),
                border: InputBorder.none,
                hintText: 'Enter Python code...',
                hintStyle: TextStyle(color: _kMuted),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChartPanel() {
    final config = _chartBuilder.activeChart;
    return Container(
      color: _kSurface,
      padding: const EdgeInsets.all(16),
      child: config != null
          ? _chartBuilder.buildWidget(config)
          : const Center(
              child: Text(
                'Charts will appear here when Python calls\n'
                'chart_line(), chart_bar(), chart_scatter(), etc.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _kMuted, fontSize: 13),
              ),
            ),
    );
  }

  Widget _buildLogPanel() {
    return Container(
      color: const Color(0xFF1B1B1B),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            decoration: const BoxDecoration(
              color: _kSurface,
              border: Border(
                bottom: BorderSide(color: _kBorder),
              ),
            ),
            child: Row(
              children: [
                const Text(
                  'OUTPUT',
                  style: TextStyle(
                    color: _kMuted,
                    fontSize: 11,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => setState(_logLines.clear),
                  child: const Text(
                    'Clear',
                    style: TextStyle(
                      color: _kBlue,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(8),
              itemCount: _logLines.length,
              itemBuilder: (_, i) {
                final entry = _logLines[i];
                return Text(
                  entry.text,
                  style: TextStyle(
                    fontFamily: 'Consolas, Monaco, monospace',
                    fontSize: 12,
                    height: 1.5,
                    color: entry.color,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LogEntry {
  const _LogEntry(this.text, this.color);
  final String text;
  final Color color;
}
