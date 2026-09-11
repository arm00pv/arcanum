import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/formatters.dart';

/// Maps a normalised 0..1 score onto the shared red -> amber -> green scale.
Color _bandColor(ArcanumColors c, double t) {
  final v = t.isFinite ? t.clamp(0.0, 1.0).toDouble() : 0.0;
  return v < 0.5
      ? Color.lerp(c.negative, c.warning, v * 2)!
      : Color.lerp(c.warning, c.positive, (v - 0.5) * 2)!;
}

/// A semicircular 0..100 gauge with a needle that sweeps into place on first
/// build.
///
/// The value arc is coloured on a red -> amber -> green scale, tick marks sit
/// at 35 / 50 / 65 to mark the "avoid / neutral / chase" bands, and an optional
/// [confidence] arc is drawn just inside the track at reduced opacity.
class TrendGauge extends StatefulWidget {
  /// Creates a trend gauge.
  const TrendGauge({
    super.key,
    required this.score,
    this.label,
    this.size = 180,
    this.confidence,
    this.strokeWidth = 12,
    this.semanticLabel,
  });

  /// The score, 0..100. Values outside the range are clamped.
  final double score;

  /// Caption rendered below the gauge.
  final String? label;

  /// Width of the gauge in logical pixels. Defaults to 180.
  final double size;

  /// Optional model confidence, 0..1, drawn as a thin inner arc.
  final double? confidence;

  /// Thickness of the track and value arcs.
  final double strokeWidth;

  /// Optional semantics override.
  final String? semanticLabel;

  @override
  State<TrendGauge> createState() => _TrendGaugeState();
}

class _TrendGaugeState extends State<TrendGauge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _sweep = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didUpdateWidget(TrendGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.score != widget.score) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final score = widget.score.isFinite
        ? widget.score.clamp(0.0, 100.0).toDouble()
        : 0.0;
    final t = score / 100;
    final color = _bandColor(c, t);
    final painterHeight = widget.size / 2 + widget.strokeWidth + 2;
    final caption = widget.label;

    return Semantics(
      label:
          widget.semanticLabel ??
          '${caption ?? 'Trend score'}: ${score.round()} out of 100',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: widget.size,
            height: painterHeight,
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (BuildContext context, Widget? child) => CustomPaint(
                painter: _GaugePainter(
                  t: _sweep.value * t,
                  color: color,
                  trackColor: c.hairlineStrong,
                  tickColor: c.textTertiary.withValues(alpha: 0.6),
                  needleColor: c.textPrimary.withValues(alpha: 0.85),
                  strokeWidth: widget.strokeWidth,
                  confidence: widget.confidence,
                  confidenceColor: color,
                ),
                child: child,
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: widget.strokeWidth * 0.25),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      Fmt.percentPlain(score, digits: 0),
                      maxLines: 1,
                      style: context.t.displaySmall?.copyWith(
                        fontSize: widget.size * 0.26,
                        color: color,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (caption != null) ...<Widget>[
            const SizedBox(height: 8),
            SizedBox(
              width: widget.size,
              child: Text(
                caption,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.t.labelMedium?.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A compact horizontal score bar for list rows.
class ScoreBar extends StatelessWidget {
  /// Creates a horizontal score bar.
  const ScoreBar({
    super.key,
    required this.score,
    this.width = 64,
    this.height = 6,
    this.semanticLabel,
  });

  /// The score, 0..100. Values outside the range are clamped.
  final double score;

  /// Width of the bar in logical pixels.
  final double width;

  /// Height (and pill radius driver) of the bar in logical pixels.
  final double height;

  /// Optional semantics override.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final value = score.isFinite ? score.clamp(0.0, 100.0).toDouble() : 0.0;
    final t = value / 100;
    final color = _bandColor(c, t);

    return Semantics(
      label: semanticLabel ?? 'Score ${value.round()} of 100',
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: ColoredBox(color: c.hairlineStrong)),
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: t,
                  child: ColoredBox(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the gauge track, ticks, value arc, confidence arc and needle.
class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.t,
    required this.color,
    required this.trackColor,
    required this.tickColor,
    required this.needleColor,
    required this.strokeWidth,
    this.confidence,
    this.confidenceColor,
  });

  /// Animated sweep position, 0..1.
  final double t;

  /// Colour of the value arc, already resolved from the score band.
  final Color color;

  /// Colour of the unfilled track.
  final Color trackColor;

  /// Colour of the 35 / 50 / 65 tick marks.
  final Color tickColor;

  /// Colour of the needle and its hub.
  final Color needleColor;

  /// Thickness of the track and value arcs.
  final double strokeWidth;

  /// Optional confidence, 0..1.
  final double? confidence;

  /// Colour of the confidence arc. Defaults to [color].
  final Color? confidenceColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || size.width <= strokeWidth) return;

    final radius = (size.width - strokeWidth) / 2;
    final center = Offset(size.width / 2, size.height - strokeWidth / 2 - 1);
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = math.pi;

    canvas.drawArc(
      rect,
      start,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..color = trackColor,
    );

    final conf = confidence;
    if (conf != null && conf.isFinite) {
      final ct = conf.clamp(0.0, 1.0).toDouble();
      final cr = radius - strokeWidth * 1.7;
      if (cr > 2 && ct > 0) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: cr),
          start,
          math.pi * ct,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.5, strokeWidth * 0.30)
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true
            ..color = (confidenceColor ?? color).withValues(alpha: 0.35),
        );
      }
    }

    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, strokeWidth * 0.16)
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..color = tickColor;
    final tickOuter = radius - strokeWidth / 2 - 2;
    final tickInner = tickOuter - math.max(3, strokeWidth * 0.45);
    if (tickOuter > tickInner) {
      for (final v in const <double>[35, 50, 65]) {
        final a = start + math.pi * (v / 100);
        final dir = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(
          center + dir * tickOuter,
          center + dir * tickInner,
          tickPaint,
        );
      }
    }

    final sweep = t.isFinite ? t.clamp(0.0, 1.0).toDouble() : 0.0;
    if (sweep > 0) {
      canvas.drawArc(
        rect,
        start,
        math.pi * sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true
          ..color = color,
      );
    }

    final a = start + math.pi * sweep;
    final dir = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(
      center,
      center + dir * (radius * 0.80),
      Paint()
        ..strokeWidth = math.max(1.5, strokeWidth * 0.22)
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..color = needleColor,
    );
    canvas.drawCircle(
      center,
      math.max(2, strokeWidth * 0.30),
      Paint()
        ..isAntiAlias = true
        ..color = needleColor,
    );
    canvas.drawCircle(
      center,
      math.max(1, strokeWidth * 0.13),
      Paint()
        ..isAntiAlias = true
        ..color = trackColor,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.tickColor != tickColor ||
      oldDelegate.needleColor != needleColor ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.confidence != confidence ||
      oldDelegate.confidenceColor != confidenceColor;
}
