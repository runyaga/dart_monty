import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_web/dart_monty_web.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// VS Code dark palette — matches the plain-Dart JS demo site.
const _kBg = Color(0xFF1E1E1E);
const _kSurface = Color(0xFF252526);
const _kBorder = Color(0xFF404040);
const _kText = Color(0xFFD4D4D4);
const _kMuted = Color(0xFF808080);
const _kBlue = Color(0xFF569CD6);
const _kYellow = Color(0xFFDCDCAA);
const _kCodeBg = Color(0xFF2D2D2D);

void main() {
  runApp(const MontyFlutterWebApp());
}

/// Root widget for the Monty Flutter Web example.
class MontyFlutterWebApp extends StatelessWidget {
  /// Creates a [MontyFlutterWebApp].
  const MontyFlutterWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monty Flutter Web',
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
        cardTheme: CardThemeData(
          color: _kSurface,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: _kBorder),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: _kSurface,
          selectedItemColor: _kBlue,
          unselectedItemColor: _kMuted,
        ),
        dividerColor: _kBorder,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: _kText),
          bodySmall: TextStyle(color: _kMuted),
        ),
      ),
      home: const MontyPage(),
    );
  }
}

/// Root page with bottom navigation: Examples, Sorting, TSP, Ladder tabs.
class MontyPage extends StatefulWidget {
  /// Creates a [MontyPage].
  const MontyPage({super.key});

  @override
  State<MontyPage> createState() => _MontyPageState();
}

class _MontyPageState extends State<MontyPage> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monty Flutter Web Example'),
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: const [
          _ExamplesPage(),
          _VisualizerPage(),
          _TspPage(),
          _LadderPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.code),
            label: 'Examples',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart),
            label: 'Sorting',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.route),
            label: 'TSP',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.checklist),
            label: 'Ladder',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Examples page — run Python snippets through MontyPlatform.instance
// ---------------------------------------------------------------------------

class _ExamplesPage extends StatefulWidget {
  const _ExamplesPage();

  @override
  State<_ExamplesPage> createState() => _ExamplesPageState();
}

class _ExamplesPageState extends State<_ExamplesPage> {
  final _controller = TextEditingController(text: _examples.first.code);
  final _outputLines = <_OutputLine>[];
  bool _running = false;
  String _selectedExample = _examples.first.label;

  // Resource limit controls
  bool _limitsEnabled = false;
  double _timeoutMs = 5000;
  double _memoryMb = 10;
  double _stackDepth = 100;

  MontyLimits? get _limits => _limitsEnabled
      ? MontyLimits(
          timeoutMs: _timeoutMs.toInt(),
          memoryBytes: (_memoryMb * 1024 * 1024).toInt(),
          stackDepth: _stackDepth.toInt(),
        )
      : null;

  Future<void> _runSelected() async {
    final example = _examples.firstWhere((e) => e.label == _selectedExample);
    setState(() {
      _running = true;
      _outputLines.clear();
    });

    if (_limitsEnabled) {
      _log(
        'Limits: timeout=${_timeoutMs.toInt()} ms, '
        'memory=${_memoryMb.toInt()} MB, '
        'stack=${_stackDepth.toInt()}',
      );
    }

    try {
      await example.runner(
        MontyPlatform.instance,
        _controller.text,
        _limits,
        _log,
      );
    } on MontyException catch (e) {
      _log('Error: ${e.message}', isError: true);
    } on Object catch (e) {
      _log('Error: $e', isError: true);
    } finally {
      setState(() => _running = false);
    }
  }

  void _log(String text, {bool isError = false}) {
    setState(() => _outputLines.add(_OutputLine(text, isError: isError)));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Spacer(),
              DropdownButton<String>(
                value: _selectedExample,
                onChanged: _running
                    ? null
                    : (v) {
                        if (v == null) return;
                        final ex = _examples.firstWhere((e) => e.label == v);
                        setState(() {
                          _selectedExample = v;
                          _controller.text = ex.code;
                          _outputLines.clear();
                        });
                      },
                items: _examples
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.label,
                        child: Text(e.label),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Resource limits
          Row(
            children: [
              Checkbox(
                value: _limitsEnabled,
                onChanged: _running
                    ? null
                    : (v) => setState(() => _limitsEnabled = v!),
              ),
              const Text('Resource limits'),
            ],
          ),
          if (_limitsEnabled) ...[
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text('Timeout: ${_timeoutMs.toInt()} ms'),
                ),
                Expanded(
                  child: Slider(
                    value: _timeoutMs,
                    min: 10,
                    max: 10000,
                    divisions: 100,
                    onChanged:
                        _running ? null : (v) => setState(() => _timeoutMs = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text('Memory: ${_memoryMb.toInt()} MB'),
                ),
                Expanded(
                  child: Slider(
                    value: _memoryMb,
                    min: 1,
                    max: 64,
                    divisions: 63,
                    onChanged:
                        _running ? null : (v) => setState(() => _memoryMb = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text('Stack: ${_stackDepth.toInt()}'),
                ),
                Expanded(
                  child: Slider(
                    value: _stackDepth,
                    min: 5,
                    max: 500,
                    divisions: 99,
                    onChanged: _running
                        ? null
                        : (v) => setState(() => _stackDepth = v),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Enter Python code...',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _running ? null : _runSelected,
            child: _running
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Run'),
          ),
          const SizedBox(height: 12),
          if (_outputLines.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _kCodeBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText.rich(
                TextSpan(
                  children: _outputLines.map((line) {
                    return TextSpan(
                      text: '${line.text}\n',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: line.isError ? Colors.red.shade300 : _kText,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Visualizer page — sorting algorithm visualizer using iterative execution
// ---------------------------------------------------------------------------

/// Available sorting algorithms.
enum _Algorithm {
  bubble,
  selection,
  insertion,
  quick,
  tim,
  shell,
  cocktail,
  sleep
}

/// Speed presets mapping labels to delay in milliseconds.
const _speedPresets = <String, int>{
  'Slow': 500,
  'Moderate': 200,
  'Medium': 100,
  'Fast': 40,
  'Fastest': 10,
};

/// Bar action types used for coloring.
enum _BarAction { none, comparing, swapped, sorted }

class _VisualizerPage extends StatefulWidget {
  const _VisualizerPage();

  @override
  State<_VisualizerPage> createState() => _VisualizerPageState();
}

class _VisualizerPageState extends State<_VisualizerPage> {
  _Algorithm _algorithm = _Algorithm.bubble;
  double _size = 30;
  String _speedLabel = 'Medium';
  bool _sorting = false;
  bool _stopRequested = false;
  MontyPlatform? _monty;

  List<int> _bars = [];
  int _highlightI = -1;
  int _highlightJ = -1;
  _BarAction _currentAction = _BarAction.none;
  bool _done = false;

  int _comparisons = 0;
  int _swaps = 0;
  int _steps = 0;
  String _status = 'Ready';

  String get _codePreview {
    final arr = List.generate(_size.toInt(), (i) => i + 1)..shuffle();
    return _templateFor(_algorithm).replaceAll('INPUT_ARRAY', arr.toString());
  }

  void _startSort() {
    setState(() {
      _sorting = true;
      _stopRequested = false;
      _comparisons = 0;
      _swaps = 0;
      _steps = 0;
      _done = false;
      _highlightI = -1;
      _highlightJ = -1;
      _currentAction = _BarAction.none;
      _status = 'Sorting...';
    });
    unawaited(_runSort());
  }

  void _stopSort() {
    _stopRequested = true;
  }

  Future<void> _runSort() async {
    final size = _size.toInt();
    final rng = Random();
    final arr = List.generate(size, (_) => rng.nextInt(100) + 1);
    setState(() => _bars = List.of(arr));

    final template = _templateFor(_algorithm);
    final code = template.replaceAll('INPUT_ARRAY', arr.toString());

    // Dispose previous instance (if any) and create a fresh one.
    await _monty?.dispose();
    final monty = DartMontyWeb();
    _monty = monty;

    try {
      var progress = await monty.start(
        code,
        externalFunctions: ['yield_state'],
      );

      while (progress is MontyPending) {
        final pending = progress;
        final args = pending.arguments;
        final stepArr = (args[0]! as List).cast<int>();
        final i = args[1]! as int;
        final j = args[2]! as int;
        final action = args[3]! as String;

        _steps++;
        if (action == 'compare') _comparisons++;
        if (action == 'swap') _swaps++;

        if (action == 'done') {
          setState(() {
            _bars = stepArr;
            _done = true;
            _highlightI = -1;
            _highlightJ = -1;
            _currentAction = _BarAction.sorted;
            _status = 'Done';
            _sorting = false;
          });
          return;
        }

        setState(() {
          _bars = stepArr;
          _highlightI = i;
          _highlightJ = j;
          _currentAction =
              action == 'swap' ? _BarAction.swapped : _BarAction.comparing;
        });

        await Future<void>.delayed(
          Duration(milliseconds: _speedPresets[_speedLabel]!),
        );

        if (_stopRequested) {
          unawaited(monty.dispose());
          _monty = null;
          setState(() {
            _status = 'Stopped';
            _sorting = false;
            _highlightI = -1;
            _highlightJ = -1;
            _currentAction = _BarAction.none;
          });
          return;
        }

        progress = await monty.resume(null);
      }

      // MontyComplete — sorting finished without a "done" yield
      setState(() {
        _done = true;
        _currentAction = _BarAction.sorted;
        _status = 'Done';
        _sorting = false;
      });
    } on MontyException catch (e) {
      setState(() {
        _status = 'Error: ${e.message}';
        _sorting = false;
      });
    } on Object catch (e) {
      setState(() {
        _status = 'Error: $e';
        _sorting = false;
      });
    }
  }

  Color _barColor(int index) {
    if (_done) return Colors.green;
    if (index == _highlightI || index == _highlightJ) {
      return switch (_currentAction) {
        _BarAction.comparing => Colors.amber,
        _BarAction.swapped => Colors.red,
        _ => _kBlue,
      };
    }
    return _kBlue;
  }

  @override
  Widget build(BuildContext context) {
    final speedKeys = _speedPresets.keys.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Algorithm selector
          SegmentedButton<_Algorithm>(
            segments: const [
              ButtonSegment(value: _Algorithm.bubble, label: Text('Bubble')),
              ButtonSegment(
                value: _Algorithm.selection,
                label: Text('Selection'),
              ),
              ButtonSegment(
                value: _Algorithm.insertion,
                label: Text('Insertion'),
              ),
              ButtonSegment(value: _Algorithm.quick, label: Text('Quick')),
              ButtonSegment(value: _Algorithm.tim, label: Text('Tim')),
              ButtonSegment(value: _Algorithm.shell, label: Text('Shell')),
              ButtonSegment(
                value: _Algorithm.cocktail,
                label: Text('Cocktail'),
              ),
              ButtonSegment(value: _Algorithm.sleep, label: Text('Sleep')),
            ],
            selected: {_algorithm},
            onSelectionChanged:
                _sorting ? null : (v) => setState(() => _algorithm = v.first),
          ),
          const SizedBox(height: 12),

          // Size slider
          Row(
            children: [
              const Text('Size:'),
              Expanded(
                child: Slider(
                  value: _size,
                  min: 10,
                  max: 100,
                  divisions: 18,
                  label: _size.toInt().toString(),
                  onChanged: _sorting ? null : (v) => setState(() => _size = v),
                ),
              ),
              SizedBox(width: 32, child: Text(_size.toInt().toString())),
            ],
          ),

          // Speed slider
          Row(
            children: [
              const Text('Speed:'),
              Expanded(
                child: Slider(
                  value: speedKeys.indexOf(_speedLabel).toDouble(),
                  max: (speedKeys.length - 1).toDouble(),
                  divisions: speedKeys.length - 1,
                  label: _speedLabel,
                  onChanged: (v) {
                    setState(() => _speedLabel = speedKeys[v.toInt()]);
                  },
                ),
              ),
              SizedBox(width: 64, child: Text(_speedLabel)),
            ],
          ),
          const SizedBox(height: 8),

          // Start / Stop button
          ElevatedButton(
            onPressed: _sorting ? _stopSort : _startSort,
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _sorting ? Colors.red.shade700 : Colors.green.shade700,
              foregroundColor: _kText,
            ),
            child: Text(_sorting ? 'Stop' : 'Start'),
          ),
          const SizedBox(height: 12),

          // Bar chart
          SizedBox(
            height: 280,
            child: _bars.isEmpty
                ? const Center(child: Text('Press Start to begin'))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final maxVal =
                          _bars.reduce((a, b) => a > b ? a : b).toDouble();
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(_bars.length, (i) {
                          final height =
                              maxVal > 0 ? (_bars[i] / maxVal) * 270 : 0.0;
                          return Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 0.5),
                              child: Container(
                                height: height,
                                decoration: BoxDecoration(
                                  color: _barColor(i),
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),

          // Stats row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Text('Comparisons: $_comparisons'),
              Text('Swaps: $_swaps'),
              Text('Steps: $_steps'),
            ],
          ),
          const SizedBox(height: 4),
          Text(_status, textAlign: TextAlign.center),
          const SizedBox(height: 12),

          // Code preview
          SizedBox(
            height: 200,
            child: TextField(
              controller: TextEditingController(text: _codePreview),
              maxLines: null,
              expands: true,
              readOnly: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Python code',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TSP page — Traveling Salesman Problem visualizer
// ---------------------------------------------------------------------------

enum _TspAlgorithm { nearestNeighbor, twoOpt }

class _TspPage extends StatefulWidget {
  const _TspPage();

  @override
  State<_TspPage> createState() => _TspPageState();
}

class _TspPageState extends State<_TspPage> {
  _TspAlgorithm _algorithm = _TspAlgorithm.nearestNeighbor;
  double _cityCount = 15;
  String _speedLabel = 'Medium';
  bool _running = false;
  bool _stopRequested = false;
  MontyPlatform? _monty;

  List<List<int>> _cities = [];
  List<int> _route = [];
  double _distance = 0;
  int _iterations = 0;
  bool _done = false;
  String _status = 'Ready';

  String get _codePreview {
    final rng = Random();
    final cities = List.generate(
      _cityCount.toInt(),
      (_) => [rng.nextInt(100), rng.nextInt(100)],
    );
    return _tspTemplateFor(_algorithm)
        .replaceAll('INPUT_CITIES', cities.toString());
  }

  void _startTsp() {
    setState(() {
      _running = true;
      _stopRequested = false;
      _iterations = 0;
      _distance = 0;
      _done = false;
      _route = [];
      _status = 'Running...';
    });
    unawaited(_runTsp());
  }

  void _stopTsp() {
    _stopRequested = true;
  }

  Future<void> _runTsp() async {
    final count = _cityCount.toInt();
    final rng = Random();
    final cities = List.generate(
      count,
      (_) => [rng.nextInt(100), rng.nextInt(100)],
    );
    setState(() {
      _cities = cities;
      _route = [];
    });

    final template = _tspTemplateFor(_algorithm);
    final code = template.replaceAll('INPUT_CITIES', cities.toString());

    await _monty?.dispose();
    final monty = DartMontyWeb();
    _monty = monty;

    try {
      var progress = await monty.start(
        code,
        externalFunctions: ['yield_state'],
      );

      while (progress is MontyPending) {
        final args = progress.arguments;
        final routeData = (args[0]! as List).cast<int>();
        final dist = (args[1]! as num).toDouble();
        final iter = args[2]! as int;
        final action = args[3]! as String;

        if (action == 'done') {
          setState(() {
            _route = routeData;
            _distance = dist;
            _iterations = iter;
            _done = true;
            _status = 'Done';
            _running = false;
          });
          return;
        }

        setState(() {
          _route = routeData;
          _distance = dist;
          _iterations = iter;
        });

        await Future<void>.delayed(
          Duration(milliseconds: _speedPresets[_speedLabel]!),
        );

        if (_stopRequested) {
          unawaited(monty.dispose());
          _monty = null;
          setState(() {
            _status = 'Stopped';
            _running = false;
          });
          return;
        }

        progress = await monty.resume(null);
      }

      setState(() {
        _done = true;
        _status = 'Done';
        _running = false;
      });
    } on MontyException catch (e) {
      setState(() {
        _status = 'Error: ${e.message}';
        _running = false;
      });
    } on Object catch (e) {
      setState(() {
        _status = 'Error: $e';
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final speedKeys = _speedPresets.keys.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<_TspAlgorithm>(
            segments: const [
              ButtonSegment(
                value: _TspAlgorithm.nearestNeighbor,
                label: Text('Nearest Neighbor'),
              ),
              ButtonSegment(
                value: _TspAlgorithm.twoOpt,
                label: Text('2-opt'),
              ),
            ],
            selected: {_algorithm},
            onSelectionChanged:
                _running ? null : (v) => setState(() => _algorithm = v.first),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Cities:'),
              Expanded(
                child: Slider(
                  value: _cityCount,
                  min: 5,
                  max: 40,
                  divisions: 7,
                  label: _cityCount.toInt().toString(),
                  onChanged:
                      _running ? null : (v) => setState(() => _cityCount = v),
                ),
              ),
              SizedBox(
                width: 32,
                child: Text(_cityCount.toInt().toString()),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Speed:'),
              Expanded(
                child: Slider(
                  value: speedKeys.indexOf(_speedLabel).toDouble(),
                  max: (speedKeys.length - 1).toDouble(),
                  divisions: speedKeys.length - 1,
                  label: _speedLabel,
                  onChanged: (v) {
                    setState(() => _speedLabel = speedKeys[v.toInt()]);
                  },
                ),
              ),
              SizedBox(width: 64, child: Text(_speedLabel)),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _running ? _stopTsp : _startTsp,
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  _running ? Colors.red.shade700 : Colors.green.shade700,
              foregroundColor: _kText,
            ),
            child: Text(_running ? 'Stop' : 'Start'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 350,
            child: _cities.isEmpty
                ? const Center(child: Text('Press Start to begin'))
                : CustomPaint(
                    size: const Size(double.infinity, 350),
                    painter: _TspPainter(
                      cities: _cities,
                      route: _route,
                      done: _done,
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Text('Distance: ${_distance.toStringAsFixed(1)}'),
              Text('Iterations: $_iterations'),
            ],
          ),
          const SizedBox(height: 4),
          Text(_status, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: TextField(
              controller: TextEditingController(text: _codePreview),
              maxLines: null,
              expands: true,
              readOnly: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Python code',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _TspPainter extends CustomPainter {
  _TspPainter({
    required this.cities,
    required this.route,
    required this.done,
  });

  final List<List<int>> cities;
  final List<int> route;
  final bool done;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeCap = StrokeCap.round;

    const pad = 20.0;
    final w = size.width - 2 * pad;
    final h = size.height - 2 * pad;

    Offset toCanvas(List<int> city) {
      return Offset(pad + city[0] / 100 * w, pad + city[1] / 100 * h);
    }

    // Draw route lines.
    if (route.length > 1) {
      paint
        ..color = done ? Colors.green : _kBlue
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;

      final path = Path();
      final start = toCanvas(cities[route[0]]);
      path.moveTo(start.dx, start.dy);
      for (var i = 1; i < route.length; i++) {
        final p = toCanvas(cities[route[i]]);
        path.lineTo(p.dx, p.dy);
      }
      if (route.length == cities.length) {
        path.lineTo(start.dx, start.dy);
      }
      canvas.drawPath(path, paint);
    }

    // Draw city dots.
    paint
      ..style = PaintingStyle.fill
      ..color = _kBlue;
    for (final city in cities) {
      canvas.drawCircle(toCanvas(city), 5, paint);
    }

    // Draw city index labels for small counts.
    if (cities.length <= 25) {
      final tp = TextPainter(textDirection: TextDirection.ltr);
      for (var i = 0; i < cities.length; i++) {
        final offset = toCanvas(cities[i]);
        tp
          ..text = TextSpan(
            text: '$i',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 8,
              fontWeight: FontWeight.bold,
            ),
          )
          ..layout()
          ..paint(
            canvas,
            Offset(offset.dx - tp.width / 2, offset.dy - tp.height / 2),
          );
      }
    }
  }

  @override
  bool shouldRepaint(_TspPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Ladder page — runs cross-platform test fixtures and reports pass/fail
// ---------------------------------------------------------------------------

class _LadderPage extends StatefulWidget {
  const _LadderPage();

  @override
  State<_LadderPage> createState() => _LadderPageState();
}

enum _TestStatus { pending, running, pass, fail, skip }

class _TestResult {
  _TestResult({
    required this.name,
    required this.tier,
    required this.code,
    this.status = _TestStatus.pending,
    this.detail,
  });
  final String name;
  final int tier;
  final String code;
  _TestStatus status;
  String? detail;
}

class _LadderPageState extends State<_LadderPage> {
  bool _running = false;
  final _results = <_TestResult>[];
  int _pass = 0;
  int _fail = 0;
  int _skip = 0;
  final _expandedTiers = <int>{};

  Future<void> _runAll() async {
    setState(() {
      _running = true;
      _results.clear();
      _pass = 0;
      _fail = 0;
      _skip = 0;
      _expandedTiers.clear();
    });

    final tierFiles = [
      'tier_01_expressions.json',
      'tier_02_variables.json',
      'tier_03_control_flow.json',
      'tier_04_functions.json',
      'tier_05_errors.json',
      'tier_06_external_fns.json',
    ];

    // Create a single Monty instance for all fixtures.
    final monty = DartMontyWeb();

    for (final file in tierFiles) {
      try {
        final response = await http.get(Uri.parse('fixtures/$file'));
        if (response.statusCode != 200) {
          setState(() {
            _results.add(
              _TestResult(
                name: 'Load $file',
                tier: 0,
                code: '',
                status: _TestStatus.fail,
                detail: 'HTTP ${response.statusCode}',
              ),
            );
            _fail++;
          });
          continue;
        }
        final fixtures = json.decode(response.body) as List;

        for (final fx in fixtures) {
          final fixture = fx as Map<String, dynamic>;
          final result = _TestResult(
            name: fixture['name'] as String,
            tier: fixture['tier'] as int,
            code: fixture['code'] as String,
            status: _TestStatus.running,
          );
          setState(() => _results.add(result));

          await _runFixture(monty, fixture, result);
          setState(() {});
        }
      } on Object catch (e) {
        setState(() {
          _results.add(
            _TestResult(
              name: 'Load $file',
              tier: 0,
              code: '',
              status: _TestStatus.fail,
              detail: e.toString(),
            ),
          );
          _fail++;
        });
      }
    }

    await monty.dispose();
    setState(() => _running = false);
  }

  Future<void> _runFixture(
    MontyPlatform monty,
    Map<String, dynamic> fixture,
    _TestResult result,
  ) async {
    final code = fixture['code'] as String;
    final expected = fixture['expected'];
    final expectedContains = fixture['expectedContains'] as String?;
    final expectError = fixture['expectError'] as bool? ?? false;
    final externalFunctions =
        (fixture['externalFunctions'] as List?)?.cast<String>();
    final resumeValues = fixture['resumeValues'] as List?;
    final resumeErrors = fixture['resumeErrors'] as List?;

    try {
      if (externalFunctions != null && externalFunctions.isNotEmpty) {
        await _runIterative(
          monty,
          code,
          externalFunctions,
          resumeValues,
          resumeErrors,
          expected,
          expectedContains,
          result,
        );
      } else if (expectError) {
        await _runExpectError(monty, code, fixture, result);
      } else {
        await _runSimple(monty, code, expected, expectedContains, result);
      }
    } on Object catch (e) {
      result
        ..status = _TestStatus.fail
        ..detail = e.toString();
      _fail++;
    }
  }

  Future<void> _runSimple(
    MontyPlatform monty,
    String code,
    Object? expected,
    String? expectedContains,
    _TestResult result,
  ) async {
    final montyResult = await monty.run(code);
    final value = montyResult.value;

    if (expectedContains != null) {
      if (value.toString().contains(expectedContains)) {
        result
          ..status = _TestStatus.pass
          ..detail = 'value: $value';
        _pass++;
      } else {
        result
          ..status = _TestStatus.fail
          ..detail = 'expected contains "$expectedContains", got: $value';
        _fail++;
      }
    } else if (_valuesMatch(value, expected)) {
      result
        ..status = _TestStatus.pass
        ..detail = 'value: $value';
      _pass++;
    } else {
      result
        ..status = _TestStatus.fail
        ..detail = 'expected: $expected, got: $value';
      _fail++;
    }
  }

  Future<void> _runExpectError(
    MontyPlatform monty,
    String code,
    Map<String, dynamic> fixture,
    _TestResult result,
  ) async {
    final errorContains = fixture['errorContains'] as String?;
    try {
      final montyResult = await monty.run(code);
      result
        ..status = _TestStatus.fail
        ..detail = 'expected error, got value: ${montyResult.value}';
      _fail++;
    } on MontyException catch (e) {
      if (errorContains != null && !e.message.contains(errorContains)) {
        result
          ..status = _TestStatus.fail
          ..detail = 'expected error containing "$errorContains", '
              'got: ${e.message}';
        _fail++;
      } else {
        result
          ..status = _TestStatus.pass
          ..detail = 'error: ${e.message}';
        _pass++;
      }
    }
  }

  Future<void> _runIterative(
    MontyPlatform monty,
    String code,
    List<String> externalFunctions,
    List<dynamic>? resumeValues,
    List<dynamic>? resumeErrors,
    Object? expected,
    String? expectedContains,
    _TestResult result,
  ) async {
    var progress = await monty.start(
      code,
      externalFunctions: externalFunctions,
    );

    var resumeIdx = 0;
    while (progress is MontyPending) {
      if (resumeErrors != null && resumeIdx < resumeErrors.length) {
        progress =
            await monty.resumeWithError(resumeErrors[resumeIdx].toString());
      } else if (resumeValues != null && resumeIdx < resumeValues.length) {
        progress = await monty.resume(resumeValues[resumeIdx]);
      } else {
        progress = await monty.resume(null);
      }
      resumeIdx++;
    }

    final complete = progress as MontyComplete;
    final value = complete.result.value;

    if (expectedContains != null) {
      if (value.toString().contains(expectedContains)) {
        result
          ..status = _TestStatus.pass
          ..detail = 'value: $value';
        _pass++;
      } else {
        result
          ..status = _TestStatus.fail
          ..detail = 'expected contains "$expectedContains", got: $value';
        _fail++;
      }
    } else if (_valuesMatch(value, expected)) {
      result
        ..status = _TestStatus.pass
        ..detail = 'value: $value';
      _pass++;
    } else {
      result
        ..status = _TestStatus.fail
        ..detail = 'expected: $expected, got: $value';
      _fail++;
    }
  }

  bool _valuesMatch(Object? actual, Object? expected) {
    if (actual == expected) return true;
    if (actual is num && expected is num) {
      return (actual - expected).abs() < 0.001;
    }
    return actual.toString() == expected.toString();
  }

  @override
  Widget build(BuildContext context) {
    final tiers = <int>{};
    for (final r in _results) {
      tiers.add(r.tier);
    }
    final sortedTiers = tiers.toList()..sort();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ElevatedButton(
                onPressed: _running ? null : _runAll,
                child: _running
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Run All'),
              ),
              const SizedBox(width: 16),
              if (_results.isNotEmpty) ...[
                _badge('PASS', _pass, Colors.green),
                const SizedBox(width: 8),
                _badge('FAIL', _fail, Colors.red),
                const SizedBox(width: 8),
                _badge('SKIP', _skip, Colors.grey),
                const Spacer(),
                Text(
                  '${_pass + _fail + _skip} / ${_results.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final tier in sortedTiers) ...[
                _tierHeader(tier),
                if (_expandedTiers.contains(tier))
                  for (final r in _results.where((r) => r.tier == tier))
                    _testCard(r),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _badge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label: $count',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _tierHeader(int tier) {
    final expanded = _expandedTiers.contains(tier);
    final tierResults = _results.where((r) => r.tier == tier);
    final tierPass =
        tierResults.where((r) => r.status == _TestStatus.pass).length;
    final tierTotal = tierResults.length;

    return InkWell(
      onTap: () {
        setState(() {
          if (expanded) {
            _expandedTiers.remove(tier);
          } else {
            _expandedTiers.add(tier);
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(expanded ? Icons.expand_less : Icons.expand_more),
            const SizedBox(width: 8),
            Text(
              'Tier $tier',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const Spacer(),
            Text(
              '$tierPass / $tierTotal',
              style: TextStyle(
                color: tierPass == tierTotal ? Colors.green : Colors.orange,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _testCard(_TestResult result) {
    final statusColor = switch (result.status) {
      _TestStatus.pass => Colors.green,
      _TestStatus.fail => Colors.red,
      _TestStatus.skip => Colors.grey,
      _TestStatus.running => _kBlue,
      _TestStatus.pending => _kMuted,
    };
    final statusLabel = switch (result.status) {
      _TestStatus.pass => 'PASS',
      _TestStatus.fail => 'FAIL',
      _TestStatus.skip => 'SKIP',
      _TestStatus.running => 'RUN',
      _TestStatus.pending => '...',
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ExpansionTile(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(result.name)),
          ],
        ),
        initiallyExpanded: result.status == _TestStatus.fail,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _kCodeBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    result.code,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                if (result.detail != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    result.detail!,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: result.status == _TestStatus.fail
                          ? Colors.red.shade300
                          : Colors.green.shade300,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Algorithm templates — same Python code as desktop/web demos
// ---------------------------------------------------------------------------

String _templateFor(_Algorithm algo) {
  return switch (algo) {
    _Algorithm.bubble => '''
arr = INPUT_ARRAY[:]
n = len(arr)
i = 0
while i < n:
    j = 0
    while j < n - i - 1:
        yield_state(arr, j, j + 1, "compare")
        if arr[j] > arr[j + 1]:
            tmp = arr[j]
            arr[j] = arr[j + 1]
            arr[j + 1] = tmp
            yield_state(arr, j, j + 1, "swap")
        j = j + 1
    i = i + 1
yield_state(arr, -1, -1, "done")
arr''',
    _Algorithm.selection => '''
arr = INPUT_ARRAY[:]
n = len(arr)
i = 0
while i < n:
    min_idx = i
    j = i + 1
    while j < n:
        yield_state(arr, min_idx, j, "compare")
        if arr[j] < arr[min_idx]:
            min_idx = j
        j = j + 1
    if min_idx != i:
        tmp = arr[i]
        arr[i] = arr[min_idx]
        arr[min_idx] = tmp
        yield_state(arr, i, min_idx, "swap")
    i = i + 1
yield_state(arr, -1, -1, "done")
arr''',
    _Algorithm.insertion => '''
arr = INPUT_ARRAY[:]
n = len(arr)
i = 1
while i < n:
    key = arr[i]
    j = i - 1
    while j >= 0:
        yield_state(arr, j, i, "compare")
        if arr[j] > key:
            arr[j + 1] = arr[j]
            yield_state(arr, j, j + 1, "swap")
            j = j - 1
        else:
            break
        if j < 0:
            break
    arr[j + 1] = key
    i = i + 1
yield_state(arr, -1, -1, "done")
arr''',
    _Algorithm.quick => '''
arr = INPUT_ARRAY[:]
n = len(arr)
stack = [[0, n - 1]]
while len(stack) > 0:
    pair = stack[len(stack) - 1]
    stack = stack[:len(stack) - 1]
    low = pair[0]
    high = pair[1]
    if low < high:
        pivot = arr[high]
        i = low - 1
        j = low
        while j < high:
            yield_state(arr, j, high, "compare")
            if arr[j] <= pivot:
                i = i + 1
                if i != j:
                    tmp = arr[i]
                    arr[i] = arr[j]
                    arr[j] = tmp
                    yield_state(arr, i, j, "swap")
            j = j + 1
        tmp = arr[i + 1]
        arr[i + 1] = arr[high]
        arr[high] = tmp
        yield_state(arr, i + 1, high, "swap")
        p = i + 1
        stack.append([low, p - 1])
        stack.append([p + 1, high])
yield_state(arr, -1, -1, "done")
arr''',
    _Algorithm.tim => '''
arr = INPUT_ARRAY[:]
n = len(arr)
RUN = 8
start = 0
while start < n:
    end = start + RUN
    if end > n:
        end = n
    i = start + 1
    while i < end:
        key = arr[i]
        j = i - 1
        while j >= start:
            yield_state(arr, j, i, "compare")
            if arr[j] > key:
                arr[j + 1] = arr[j]
                yield_state(arr, j, j + 1, "swap")
                j = j - 1
            else:
                break
            if j < start:
                break
        arr[j + 1] = key
        i = i + 1
    start = start + RUN
size = RUN
while size < n:
    left = 0
    while left < n:
        mid = left + size
        right = left + 2 * size
        if mid > n:
            mid = n
        if right > n:
            right = n
        if mid < right:
            left_half = arr[left:mid]
            right_half = arr[mid:right]
            i = 0
            j = 0
            k = left
            while i < len(left_half) and j < len(right_half):
                yield_state(arr, k, k + 1, "compare")
                if left_half[i] <= right_half[j]:
                    arr[k] = left_half[i]
                    yield_state(arr, k, k, "swap")
                    i = i + 1
                else:
                    arr[k] = right_half[j]
                    yield_state(arr, k, k, "swap")
                    j = j + 1
                k = k + 1
            while i < len(left_half):
                arr[k] = left_half[i]
                yield_state(arr, k, k, "swap")
                i = i + 1
                k = k + 1
            while j < len(right_half):
                arr[k] = right_half[j]
                yield_state(arr, k, k, "swap")
                j = j + 1
                k = k + 1
        left = left + 2 * size
    size = size * 2
yield_state(arr, -1, -1, "done")
arr''',
    _Algorithm.shell => '''
arr = INPUT_ARRAY[:]
n = len(arr)
gap = n // 2
while gap > 0:
    i = gap
    while i < n:
        temp = arr[i]
        j = i
        while j >= gap:
            yield_state(arr, j, j - gap, "compare")
            if arr[j - gap] > temp:
                arr[j] = arr[j - gap]
                yield_state(arr, j, j - gap, "swap")
                j = j - gap
            else:
                break
            if j < gap:
                break
        arr[j] = temp
        i = i + 1
    gap = gap // 2
yield_state(arr, -1, -1, "done")
arr''',
    _Algorithm.cocktail => '''
arr = INPUT_ARRAY[:]
n = len(arr)
swapped = True
start = 0
end = n - 1
while swapped:
    swapped = False
    i = start
    while i < end:
        yield_state(arr, i, i + 1, "compare")
        if arr[i] > arr[i + 1]:
            tmp = arr[i]
            arr[i] = arr[i + 1]
            arr[i + 1] = tmp
            yield_state(arr, i, i + 1, "swap")
            swapped = True
        i = i + 1
    if not swapped:
        break
    swapped = False
    end = end - 1
    i = end - 1
    while i >= start:
        yield_state(arr, i, i + 1, "compare")
        if arr[i] > arr[i + 1]:
            tmp = arr[i]
            arr[i] = arr[i + 1]
            arr[i + 1] = tmp
            yield_state(arr, i, i + 1, "swap")
            swapped = True
        i = i - 1
    start = start + 1
yield_state(arr, -1, -1, "done")
arr''',
    _Algorithm.sleep => '''
arr = INPUT_ARRAY[:]
n = len(arr)
result = []
max_val = arr[0]
i = 1
while i < n:
    if arr[i] > max_val:
        max_val = arr[i]
    i = i + 1
t = 1
while t <= max_val:
    i = 0
    while i < n:
        yield_state(arr, i, len(result), "compare")
        if arr[i] == t:
            result.append(arr[i])
            yield_state(arr, i, len(result) - 1, "swap")
        i = i + 1
    t = t + 1
i = 0
while i < n:
    arr[i] = result[i]
    i = i + 1
yield_state(arr, -1, -1, "done")
arr''',
  };
}

// ---------------------------------------------------------------------------
// TSP algorithm templates
// ---------------------------------------------------------------------------

String _tspTemplateFor(_TspAlgorithm algo) {
  return switch (algo) {
    _TspAlgorithm.nearestNeighbor => '''
cities = INPUT_CITIES
n = len(cities)
visited = []
i = 0
while i < n:
    visited.append(False)
    i = i + 1
route = [0]
visited[0] = True
total = 0
step = 0
i = 0
while i < n - 1:
    current = route[len(route) - 1]
    best = -1
    best_dist = 999999
    j = 0
    while j < n:
        if not visited[j]:
            dx = cities[current][0] - cities[j][0]
            dy = cities[current][1] - cities[j][1]
            d = (dx * dx + dy * dy) ** 0.5
            if d < best_dist:
                best_dist = d
                best = j
        j = j + 1
    visited[best] = True
    route.append(best)
    total = total + best_dist
    step = step + 1
    yield_state(route, total, step, "step")
    i = i + 1
dx = cities[route[n - 1]][0] - cities[route[0]][0]
dy = cities[route[n - 1]][1] - cities[route[0]][1]
total = total + (dx * dx + dy * dy) ** 0.5
yield_state(route, total, step, "done")
route''',
    _TspAlgorithm.twoOpt => '''
cities = INPUT_CITIES
n = len(cities)
route = []
i = 0
while i < n:
    route.append(i)
    i = i + 1
best_dist = 0
i = 0
while i < n:
    j = i + 1
    if j >= n:
        j = 0
    dx = cities[route[i]][0] - cities[route[j]][0]
    dy = cities[route[i]][1] - cities[route[j]][1]
    best_dist = best_dist + (dx * dx + dy * dy) ** 0.5
    i = i + 1
step = 0
yield_state(route, best_dist, step, "step")
improved = True
while improved:
    improved = False
    i = 1
    while i < n - 1:
        j = i + 1
        while j < n:
            new_route = []
            k = 0
            while k < i:
                new_route.append(route[k])
                k = k + 1
            k = j
            while k >= i:
                new_route.append(route[k])
                k = k - 1
            k = j + 1
            while k < n:
                new_route.append(route[k])
                k = k + 1
            new_dist = 0
            k = 0
            while k < n:
                m = k + 1
                if m >= n:
                    m = 0
                dx = cities[new_route[k]][0] - cities[new_route[m]][0]
                dy = cities[new_route[k]][1] - cities[new_route[m]][1]
                new_dist = new_dist + (dx * dx + dy * dy) ** 0.5
                k = k + 1
            step = step + 1
            if new_dist < best_dist:
                route = new_route
                best_dist = new_dist
                improved = True
                yield_state(route, best_dist, step, "step")
            j = j + 1
        i = i + 1
yield_state(route, best_dist, step, "done")
route''',
  };
}

// ---------------------------------------------------------------------------
// Output line model
// ---------------------------------------------------------------------------

class _OutputLine {
  const _OutputLine(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

// ---------------------------------------------------------------------------
// Example definitions
// ---------------------------------------------------------------------------

class _Example {
  const _Example(this.label, this.code, this.runner);
  final String label;
  final String code;
  final Future<void> Function(
    MontyPlatform monty,
    String code,
    MontyLimits? limits,
    void Function(String text, {bool isError}) log,
  ) runner;
}

/// Performs an HTTP GET using package:http, returning the response body or
/// injecting an error into Python for non-2xx status codes.
Future<MontyProgress> _httpFetch(
  MontyPlatform monty,
  MontyPending pending,
  void Function(String text, {bool isError}) log,
) async {
  final url = pending.arguments.first.toString();
  log('Python called ${pending.functionName}("$url")');
  log('Fetching ...');

  try {
    final response = await http.get(Uri.parse(url));

    if (response.statusCode >= 400) {
      log('HTTP ${response.statusCode} — injecting error into Python');
      return monty.resumeWithError(
        'HTTP ${response.statusCode}: ${response.body}',
      );
    }
    log('Got ${response.body.length} bytes (HTTP ${response.statusCode})');
    return monty.resume(response.body);
  } on Object catch (e) {
    log('Network error — injecting into Python: $e', isError: true);
    return monty.resumeWithError(e.toString());
  }
}

final _examples = <_Example>[
  // 1. Expressions & resource usage
  _Example(
    '1. Expressions',
    '2 ** 8',
    (monty, code, limits, log) async {
      final result = await monty.run(code, limits: limits);
      log('Result: ${result.value}');
      log(
        'Memory: ${result.usage.memoryBytesUsed} bytes  '
        'Time: ${result.usage.timeElapsedMs} ms  '
        'Stack: ${result.usage.stackDepthUsed}',
      );
    },
  ),

  // 2. Multi-line code (Fibonacci)
  _Example(
    '2. Fibonacci',
    'def fib(n):\n'
        '    a, b = 0, 1\n'
        '    for _ in range(n):\n'
        '        a, b = b, a + b\n'
        '    return a\n'
        'fib(30)',
    (monty, code, limits, log) async {
      final result = await monty.run(code, limits: limits);
      log('Result: ${result.value}');
      log(
        'Memory: ${result.usage.memoryBytesUsed} bytes  '
        'Time: ${result.usage.timeElapsedMs} ms',
      );
    },
  ),

  // 3. Infinite loop — demonstrates timeout enforcement
  _Example(
    '3. Infinite loop',
    'x = 0\n'
        'while True:\n'
        '    x = x + 1',
    (monty, code, limits, log) async {
      final effectiveLimits = limits ?? const MontyLimits(timeoutMs: 100);
      log(
        'Running with timeout=${effectiveLimits.timeoutMs} ms '
        '(enable Resource limits to adjust)',
      );
      try {
        await monty.run(code, limits: effectiveLimits);
        log('Loop was not killed', isError: true);
      } on MontyException catch (e) {
        log('Caught: ${e.message}');
        log('The sandbox killed the infinite loop.');
      }
    },
  ),

  // 4. Error handling — Python exception caught by Dart
  _Example(
    '4. Error handling',
    'items = [1, 2, 3]\n'
        'items[10]',
    (monty, code, limits, log) async {
      try {
        await monty.run(code, limits: limits);
        log('Expected error but run() succeeded', isError: true);
      } on MontyException catch (e) {
        log('Caught: ${e.message}');
      }
    },
  ),

  // 5. Real HTTP fetch — Python calls fetch(), Dart does the actual request
  _Example(
    '5. HTTP fetch',
    'html = fetch("https://runyaga.github.io/dart_monty/")\n'
        'n = len(html)\n'
        'n',
    (monty, code, limits, log) async {
      var progress = await monty.start(
        code,
        externalFunctions: ['fetch'],
        limits: limits,
      );

      while (progress is MontyPending) {
        progress = await _httpFetch(monty, progress, log);
      }

      final complete = progress as MontyComplete;
      log('Result: ${complete.result.value}');
    },
  ),

  // 6. Error injection — HTTP 500 becomes a Python exception
  _Example(
    '6. Error injection',
    'try:\n'
        '    data = fetch("https://runyaga.github.io/dart_monty/no-such-page")\n'
        'except Exception as e:\n'
        '    result = f"caught: {e}"\n'
        'result',
    (monty, code, limits, log) async {
      var progress = await monty.start(
        code,
        externalFunctions: ['fetch'],
        limits: limits,
      );

      while (progress is MontyPending) {
        progress = await _httpFetch(monty, progress, log);
      }

      final complete = progress as MontyComplete;
      log('Result: ${complete.result.value}');
    },
  ),

  // 7. Stack depth limit — deep recursion gets killed
  _Example(
    '7. Stack overflow',
    'def recurse(n):\n'
        '    return recurse(n + 1)\n'
        'recurse(0)',
    (monty, code, limits, log) async {
      final effectiveLimits = limits ?? const MontyLimits(stackDepth: 50);
      log(
        'Running infinite recursion with stack limit='
        '${effectiveLimits.stackDepth}'
        ' (enable Resource limits to adjust)',
      );
      try {
        await monty.run(code, limits: effectiveLimits);
        log('Recursion was not killed', isError: true);
      } on MontyException catch (e) {
        log('Caught: ${e.message}');
        log('The sandbox killed the deep recursion.');
      }
    },
  ),
];
