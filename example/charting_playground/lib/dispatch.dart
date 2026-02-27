import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

import 'chart_builder.dart';
import 'df_registry.dart';

/// All external function names registered with Monty.
const allExternalFunctions = <String>[
  // DataFrame creation
  'df_create',
  'df_from_csv',
  'df_from_json',
  // DataFrame inspection
  'df_shape',
  'df_columns',
  'df_head',
  'df_tail',
  'df_describe',
  'df_to_csv',
  'df_to_json',
  'df_to_list',
  'df_column_values',
  // DataFrame transformation
  'df_select',
  'df_filter',
  'df_sort',
  'df_group_agg',
  'df_add_column',
  'df_drop',
  'df_rename',
  'df_merge',
  'df_concat',
  'df_fillna',
  'df_dropna',
  'df_transpose',
  'df_sample',
  'df_nlargest',
  'df_nsmallest',
  // DataFrame aggregation
  'df_mean',
  'df_sum',
  'df_min',
  'df_max',
  'df_std',
  'df_corr',
  'df_unique',
  'df_value_counts',
  // DataFrame lifecycle
  'df_dispose',
  'df_dispose_all',
  // Chart creation
  'chart_line',
  'chart_scatter',
  'chart_bar',
  'chart_area',
  'chart_bubble',
  'chart_pie',
  'chart_heatmap',
  'chart_spline',
  'chart_step_line',
  'chart_stacked_bar',
  // Chart modification
  'chart_add_legend',
  'chart_add_tooltip',
  'chart_set_title',
  'chart_animate',
  'chart_clear',
];

/// Dispatch a [MontyPending] call to the appropriate handler.
///
/// Returns a JSON-serializable value to pass back to Python via
/// `resume()`.
Object? dispatch(
  MontyPending pending,
  DfRegistry registry,
  ChartBuilder charts,
) {
  final fn = pending.functionName;
  final args = pending.arguments;
  final kwargs = pending.kwargs ?? const {};

  return switch (fn) {
    // ── DataFrame creation ─────────────────────────────────────────
    'df_create' => registry.create(
        args[0],
        args.length > 1 && args[1] is List
            ? (args[1]! as List).cast<String>()
            : null,
      ),
    'df_from_csv' => registry.fromCsv(
        args[0]! as String,
        args.length > 1 ? args[1]! as String : ',',
      ),
    'df_from_json' => registry.fromJson(args[0]! as String),

    // ── DataFrame inspection ───────────────────────────────────────
    'df_shape' => () {
        final df = registry.get(_int(args[0]));
        return [df.length, df.columnCount];
      }(),
    'df_columns' => registry.get(_int(args[0])).columns,
    'df_head' => registry
        .get(_int(args[0]))
        .head(args.length > 1 ? _int(args[1]) : 5)
        .rows,
    'df_tail' => registry
        .get(_int(args[0]))
        .tail(args.length > 1 ? _int(args[1]) : 5)
        .rows,
    'df_describe' => registry.get(_int(args[0])).describe(),
    'df_to_csv' => registry.get(_int(args[0])).toCsv(),
    'df_to_json' => registry.get(_int(args[0])).toJson(),
    'df_to_list' => registry.get(_int(args[0])).rows,
    'df_column_values' => registry
        .get(_int(args[0]))
        .columnValues(args[1]! as String),

    // ── DataFrame transformation ───────────────────────────────────
    'df_select' => registry.register(
        registry
            .get(_int(args[0]))
            .select((args[1]! as List).cast<String>()),
      ),
    'df_filter' => registry.register(
        registry.get(_int(args[0])).filter(
              args[1]! as String,
              args[2]! as String,
              args[3],
            ),
      ),
    'df_sort' => registry.register(
        registry.get(_int(args[0])).sort(
              args[1]! as String,
              ascending: args.length > 2 ? args[2]! as bool : true,
            ),
      ),
    'df_group_agg' => registry.register(
        registry.get(_int(args[0])).groupAgg(
              (args[1]! as List).cast<String>(),
              Map<String, String>.from(args[2]! as Map),
            ),
      ),
    'df_add_column' => registry.register(
        registry.get(_int(args[0])).addColumn(
              args[1]! as String,
              (args[2]! as List).cast<Object?>(),
            ),
      ),
    'df_drop' => registry.register(
        registry
            .get(_int(args[0]))
            .drop((args[1]! as List).cast<String>()),
      ),
    'df_rename' => registry.register(
        registry.get(_int(args[0])).rename(
              Map<String, String>.from(args[1]! as Map),
            ),
      ),
    'df_merge' => registry.register(
        registry.get(_int(args[0])).merge(
              registry.get(_int(args[1])),
              (args[2]! as List).cast<String>(),
              how: args.length > 3 ? args[3]! as String : 'inner',
            ),
      ),
    'df_concat' => () {
        final handles = (args[0]! as List).cast<num>().map(
              (h) => registry.get(h.toInt()),
            );
        final first = handles.first;
        return registry.register(
          first.concat(handles.skip(1).toList()),
        );
      }(),
    'df_fillna' => registry.register(
        registry.get(_int(args[0])).fillna(args[1]),
      ),
    'df_dropna' => registry.register(
        registry.get(_int(args[0])).dropna(),
      ),
    'df_transpose' => registry.register(
        registry.get(_int(args[0])).transpose(),
      ),
    'df_sample' => registry.register(
        registry.get(_int(args[0])).sample(_int(args[1])),
      ),
    'df_nlargest' => registry.register(
        registry
            .get(_int(args[0]))
            .nlargest(_int(args[1]), args[2]! as String),
      ),
    'df_nsmallest' => registry.register(
        registry
            .get(_int(args[0]))
            .nsmallest(_int(args[1]), args[2]! as String),
      ),

    // ── DataFrame aggregation ──────────────────────────────────────
    'df_mean' => registry
        .get(_int(args[0]))
        .computeMean(args.length > 1 ? args[1] as String? : null),
    'df_sum' => registry
        .get(_int(args[0]))
        .computeSum(args.length > 1 ? args[1] as String? : null),
    'df_min' => registry
        .get(_int(args[0]))
        .computeMin(args.length > 1 ? args[1] as String? : null),
    'df_max' => registry
        .get(_int(args[0]))
        .computeMax(args.length > 1 ? args[1] as String? : null),
    'df_std' => registry
        .get(_int(args[0]))
        .computeStd(args.length > 1 ? args[1] as String? : null),
    'df_corr' => registry.register(
        registry.get(_int(args[0])).corr(),
      ),
    'df_unique' => registry
        .get(_int(args[0]))
        .unique(args[1]! as String),
    'df_value_counts' => registry
        .get(_int(args[0]))
        .valueCounts(args[1]! as String),

    // ── DataFrame lifecycle ────────────────────────────────────────
    'df_dispose' => () {
        registry.dispose(_int(args[0]));
        return null;
      }(),
    'df_dispose_all' => () {
        registry.disposeAll();
        return null;
      }(),

    // ── Chart creation ─────────────────────────────────────────────
    'chart_line' => _createChart(
        charts, registry, 'line', args, kwargs,
      ),
    'chart_scatter' => _createChart(
        charts, registry, 'scatter', args, kwargs,
      ),
    'chart_bar' => _createChart(
        charts, registry, 'bar', args, kwargs,
      ),
    'chart_area' => _createChart(
        charts, registry, 'area', args, kwargs,
      ),
    'chart_bubble' => _createChartWithSize(
        charts, registry, 'bubble', args, kwargs,
      ),
    'chart_pie' => _createChart(
        charts, registry, 'pie', args, kwargs,
      ),
    'chart_heatmap' => _createChartWithSize(
        charts, registry, 'heatmap', args, kwargs,
      ),
    'chart_spline' => _createChart(
        charts, registry, 'line', args, kwargs,
      ),
    'chart_step_line' => _createChart(
        charts, registry, 'line', args, kwargs,
      ),
    'chart_stacked_bar' => _createChart(
        charts, registry, 'bar', args, kwargs,
      ),

    // ── Chart modification ─────────────────────────────────────────
    'chart_add_legend' => () {
        final config = charts.getConfig(_int(args[0]));
        config.legend = true;
        return _int(args[0]);
      }(),
    'chart_add_tooltip' => () {
        final config = charts.getConfig(_int(args[0]));
        config.tooltip = true;
        return _int(args[0]);
      }(),
    'chart_set_title' => () {
        charts.getConfig(_int(args[0])).title = args[1]! as String;
        return _int(args[0]);
      }(),
    'chart_animate' => () {
        final config = charts.getConfig(_int(args[0]));
        final ms = args.length > 1 ? _int(args[1]) : 500;
        config.animateDuration = Duration(milliseconds: ms);
        return _int(args[0]);
      }(),
    'chart_clear' => () {
        charts.clear();
        return null;
      }(),

    _ => throw ArgumentError('Unknown function: $fn'),
  };
}

/// Create a standard chart (line, scatter, bar, area, pie).
int _createChart(
  ChartBuilder charts,
  DfRegistry registry,
  String geom,
  List<Object?> args,
  Map<String, Object?> kwargs,
) {
  return charts.createChart(
    geom: geom,
    registry: registry,
    dfHandle: _int(args[0]),
    x: args[1]! as String,
    y: args[2]! as String,
    color: _kwargOrArg(args, kwargs, 3, 'color') as String?,
    title: _kwargOrArg(args, kwargs, 4, 'title') as String?,
  );
}

/// Create a chart that uses size mapping (bubble, heatmap).
int _createChartWithSize(
  ChartBuilder charts,
  DfRegistry registry,
  String geom,
  List<Object?> args,
  Map<String, Object?> kwargs,
) {
  return charts.createChart(
    geom: geom,
    registry: registry,
    dfHandle: _int(args[0]),
    x: args[1]! as String,
    y: args[2]! as String,
    size: args.length > 3 ? args[3] as String? : null,
    color: _kwargOrArg(args, kwargs, 4, 'color') as String?,
    title: _kwargOrArg(args, kwargs, 5, 'title') as String?,
  );
}

/// Get a value from kwargs or positional args.
Object? _kwargOrArg(
  List<Object?> args,
  Map<String, Object?> kwargs,
  int index,
  String key,
) {
  if (kwargs.containsKey(key)) return kwargs[key];
  if (index < args.length) return args[index];
  return null;
}

/// Safely convert to int.
int _int(Object? v) => (v! as num).toInt();
