import 'package:cristalyse/cristalyse.dart';
import 'package:flutter/material.dart';

import 'df_registry.dart';

/// Configuration for a chart built from an external function call.
class ChartConfig {
  ChartConfig({
    required this.geom,
    required this.data,
    required this.x,
    required this.y,
    this.color,
    this.size,
    this.title,
    this.legend = false,
    this.tooltip = false,
    this.animateDuration,
  });

  final String geom;
  final List<Map<String, dynamic>> data;
  final String x;
  final String y;
  final String? color;
  final String? size;
  String? title;
  bool legend;
  bool tooltip;
  Duration? animateDuration;
}

/// Builds Cristalyse chart widgets from [ChartConfig].
class ChartBuilder {
  int _nextId = 1;
  final _charts = <int, ChartConfig>{};

  /// The most recently created/modified chart config, for rendering.
  ChartConfig? get activeChart {
    if (_charts.isEmpty) return null;
    return _charts.values.last;
  }

  /// All chart configs by ID.
  Map<int, ChartConfig> get charts => Map.unmodifiable(_charts);

  /// Create a chart config and return its ID.
  int createChart({
    required String geom,
    required DfRegistry registry,
    required int dfHandle,
    required String x,
    required String y,
    String? color,
    String? size,
    String? title,
  }) {
    final df = registry.get(dfHandle);
    final config = ChartConfig(
      geom: geom,
      data: df.rows,
      x: x,
      y: y,
      color: color,
      size: size,
      title: title,
    );
    final id = _nextId++;
    _charts[id] = config;
    return id;
  }

  /// Get a chart config by ID.
  ChartConfig getConfig(int id) {
    final config = _charts[id];
    if (config == null) {
      throw ArgumentError('No chart with ID $id');
    }
    return config;
  }

  /// Clear all charts and reset IDs.
  void clear() {
    _charts.clear();
    _nextId = 1;
  }

  /// Build a Flutter widget from a [ChartConfig].
  Widget buildWidget(ChartConfig config) {
    var chart = CristalyseChart().data(config.data).mapping(
          x: config.x,
          y: config.y,
          color: config.color,
          size: config.size,
        );

    // Cristalyse only auto-detects categorical scales for bar/pie.
    // For other geoms with string X values, set ordinal scale explicitly.
    if (_isCategoricalColumn(config.data, config.x)) {
      chart = chart.scaleXOrdinal();
    }

    chart = switch (config.geom) {
      'line' => chart.geomLine(),
      'scatter' || 'point' => chart.geomPoint(),
      'bar' => chart.geomBar(),
      'area' => chart.geomArea(),
      'bubble' => chart.geomBubble(),
      'pie' => chart.geomPie(),
      // Cristalyse doesn't have geomHeatmap; fall back to scatter
      'heatmap' => chart.geomPoint(),
      _ => chart.geomLine(),
    };

    if (config.legend) {
      chart = chart.legend(interactive: true);
    }

    if (config.tooltip) {
      chart = chart.interaction();
    }

    if (config.animateDuration != null) {
      chart = chart.animate(duration: config.animateDuration!);
    }

    final widget = chart.build();

    if (config.title != null) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              config.title!,
              style: const TextStyle(
                color: Color(0xFFDCDCAA),
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(child: widget),
        ],
      );
    }

    return widget;
  }

  /// Returns true if the first non-null value in [column] is a String
  /// that cannot be parsed as a number.
  static bool _isCategoricalColumn(
    List<Map<String, dynamic>> data,
    String column,
  ) {
    for (final row in data) {
      final v = row[column];
      if (v == null) continue;
      if (v is num) return false;
      if (v is String && num.tryParse(v) != null) return false;
      return true; // non-numeric string → categorical
    }
    return false;
  }
}
