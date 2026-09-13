import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/quant/quant.dart';

/// The price history chart, with the model's forecast drawn as an uncertainty
/// band rather than a confident line.
///
/// Showing a band is a deliberate honesty choice: a single card's daily price is
/// a near-random walk, so a bare point forecast would overstate what is actually
/// known.
class PriceChart extends StatelessWidget {
  const PriceChart({
    super.key,
    required this.series,
    this.forecast,
    this.height = 220,
    this.showForecast = true,
  });

  /// Observed daily prices, oldest first.
  final List<PricePoint> series;

  /// Optional Holt forecast; its bands are shaded behind the line.
  final HoltForecast? forecast;

  final double height;
  final bool showForecast;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    if (series.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'Not enough price history yet',
            style: context.t.bodySmall,
          ),
        ),
      );
    }

    final firstDay = series.first.date;
    double x(DateTime d) => d.difference(firstDay).inHours / 24.0;

    final history = [for (final p in series) FlSpot(x(p.date), p.price)];

    // Forecast points continue past the last observation.
    final lastDate = series.last.date;
    final lastX = x(lastDate);
    final forecastSpots = <FlSpot>[];
    final upper80 = <FlSpot>[];
    final lower80 = <FlSpot>[];
    if (showForecast && forecast != null && forecast!.point.isNotEmpty) {
      forecastSpots.add(FlSpot(lastX, series.last.price));
      upper80.add(FlSpot(lastX, series.last.price));
      lower80.add(FlSpot(lastX, series.last.price));
      for (var h = 0; h < forecast!.point.length; h++) {
        final d = lastDate.add(Duration(days: h + 1));
        forecastSpots.add(FlSpot(x(d), forecast!.point[h]));
        if (h < forecast!.upper80.length) {
          upper80.add(FlSpot(x(d), forecast!.upper80[h]));
          lower80.add(FlSpot(x(d), forecast!.lower80[h]));
        }
      }
    }

    final allValues = <double>[
      ...series.map((p) => p.price),
      if (showForecast && forecast != null) ...forecast!.upper80,
      if (showForecast && forecast != null) ...forecast!.lower80,
    ].where((v) => v.isFinite).toList();
    if (allValues.isEmpty) return SizedBox(height: height);

    var minY = allValues.reduce((a, b) => a < b ? a : b);
    var maxY = allValues.reduce((a, b) => a > b ? a : b);
    final pad =
        (maxY - minY) * 0.12 + (maxY == minY ? maxY.abs() * 0.05 + 0.01 : 0);
    minY = (minY - pad).clamp(0, double.infinity);
    maxY = maxY + pad;

    final rising = series.last.price >= series.first.price;
    final lineColor = rising ? c.positive : c.negative;

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          minX: 0,
          maxX: (upper80.isNotEmpty ? upper80.last.x : lastX) + 1,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: (maxY - minY) / 4,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: c.hairline, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 46,
                interval: (maxY - minY) / 4,
                getTitlesWidget: (value, meta) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    Fmt.moneyAdaptive(value),
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                interval: ((upper80.isNotEmpty ? upper80.last.x : lastX) / 3)
                    .clamp(1, double.infinity),
                getTitlesWidget: (value, meta) {
                  final d = firstDay.add(Duration(days: value.round()));
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      Fmt.dateShort(d),
                      style: context.t.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => c.surfaceRaised,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    Fmt.money(s.y),
                    context.t.labelLarge ?? const TextStyle(),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            // Forecast band (shaded area between the 80% bounds).
            if (upper80.length > 1)
              LineChartBarData(
                spots: upper80,
                isCurved: true,
                curveSmoothness: 0.2,
                color: c.accent.withValues(alpha: 0.35),
                barWidth: 1,
                dotData: const FlDotData(show: false),
                dashArray: const [4, 4],
              ),
            if (lower80.length > 1)
              LineChartBarData(
                spots: lower80,
                isCurved: true,
                curveSmoothness: 0.2,
                color: c.accent.withValues(alpha: 0.35),
                barWidth: 1,
                dotData: const FlDotData(show: false),
                dashArray: const [4, 4],
                belowBarData: BarAreaData(
                  show: true,
                  color: c.accent.withValues(alpha: 0.10),
                ),
              ),
            // Observed history.
            LineChartBarData(
              spots: history,
              isCurved: true,
              curveSmoothness: 0.18,
              color: lineColor,
              barWidth: 2.2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    lineColor.withValues(alpha: 0.28),
                    lineColor.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
            // Model forecast centre line.
            if (forecastSpots.length > 1)
              LineChartBarData(
                spots: forecastSpots,
                isCurved: true,
                curveSmoothness: 0.2,
                color: c.accent.withValues(alpha: 0.9),
                barWidth: 1.6,
                dotData: const FlDotData(show: false),
                dashArray: const [6, 3],
              ),
          ],
        ),
      ),
    );
  }
}
