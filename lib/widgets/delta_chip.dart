import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/formatters.dart';

/// A compact pill that renders a signed percentage change.
///
/// The colour comes straight from [ArcanumColors.forDelta] so gains, losses and
/// flat readings stay consistent everywhere in the app. Values inside the
/// +/-0.05% dead band are treated as flat and rendered in the neutral
/// secondary text colour.
class DeltaChip extends StatelessWidget {
  /// Creates a delta pill.
  const DeltaChip({
    super.key,
    required this.percent,
    this.showArrow = true,
    this.compact = false,
    this.label,
    this.semanticLabel,
  });

  /// Signed percentage change, e.g. `12.4` for +12.4%. Null renders `--`.
  final double? percent;

  /// Whether the up/down/flat arrow glyph is shown.
  final bool showArrow;

  /// Tighter padding and smaller type, for dense list rows.
  final bool compact;

  /// Optional leading label, e.g. `'24h'`.
  final String? label;

  /// Optional semantics override.
  final String? semanticLabel;

  /// Anything smaller than this reads as flat.
  static const double flatThreshold = 0.05;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final raw = percent;
    final value = (raw != null && raw.isFinite) ? raw : null;
    final flat = value == null || value.abs() < flatThreshold;
    final color = flat ? c.textSecondary : c.forDelta(value);

    final IconData glyph;
    if (value == null) {
      glyph = Icons.remove_rounded;
    } else if (value.abs() < flatThreshold) {
      glyph = Icons.remove_rounded;
    } else if (value > 0) {
      glyph = Icons.arrow_upward_rounded;
    } else {
      glyph = Icons.arrow_downward_rounded;
    }

    final String text;
    if (value == null) {
      text = Fmt.percent(null);
    } else if (flat) {
      text = Fmt.percentPlain(0, digits: 1);
    } else {
      text = Fmt.percent(value);
    }

    final double fontSize = compact ? 10.5 : 12;
    final double glyphSize = compact ? 10 : 12;
    final EdgeInsets pad = compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 9, vertical: 4);

    final caption = label;
    return Semantics(
      label:
          semanticLabel ??
          (caption == null ? 'Change $text' : '$caption change $text'),
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Padding(
          padding: pad,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (showArrow) ...<Widget>[
                  Icon(glyph, size: glyphSize, color: color),
                  const SizedBox(width: 3),
                ],
                if (caption != null) ...<Widget>[
                  Text(
                    caption,
                    maxLines: 1,
                    style: context.t.labelMedium?.copyWith(
                      color: c.textTertiary,
                      fontSize: fontSize,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  text,
                  maxLines: 1,
                  style: context.t.labelMedium?.copyWith(
                    color: color,
                    fontSize: fontSize,
                    letterSpacing: 0,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small pill that maps a 0..1 score onto a red -> amber -> green scale.
class TrendPill extends StatelessWidget {
  /// Creates a trend pill.
  const TrendPill({
    super.key,
    required this.label,
    required this.score01,
    this.semanticLabel,
  });

  /// Short human readable label, e.g. `'Bullish'`.
  final String label;

  /// Normalised score. Values outside 0..1 are clamped.
  final double score01;

  /// Optional semantics override.
  final String? semanticLabel;

  /// Maps a normalised score onto the shared red -> amber -> green scale.
  static Color colorFor(ArcanumColors c, double score01) {
    final t = score01.isFinite ? score01.clamp(0.0, 1.0).toDouble() : 0.0;
    return t < 0.5
        ? Color.lerp(c.negative, c.warning, t * 2)!
        : Color.lerp(c.warning, c.positive, (t - 0.5) * 2)!;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = score01.isFinite ? score01.clamp(0.0, 1.0).toDouble() : 0.0;
    final color = colorFor(c, t);

    return Semantics(
      label: semanticLabel ?? '$label, ${(t * 100).round()} out of 100',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.34)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  maxLines: 1,
                  style: context.t.labelMedium?.copyWith(
                    color: color,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
