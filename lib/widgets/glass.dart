import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// A frosted-glass panel.
///
/// Layers a [BackdropFilter] blur underneath a translucent fill built from
/// [ArcanumColors.glass] over [ArcanumColors.surface], then draws a crisp 1px
/// hairline border plus a bright top-edge highlight that sells the glass look.
///
/// Every colour is resolved from the ambient theme via `context.c`, so the
/// panel adapts to the dark and light palettes without per-widget overrides.
class GlassCard extends StatelessWidget {
  /// Creates a frosted panel around [child].
  const GlassCard({
    super.key,
    this.padding,
    this.onTap,
    this.radius = 20,
    this.borderGradient,
    this.blur = 18,
    this.showHighlight = true,
    this.semanticLabel,
    required this.child,
  });

  /// Inner padding applied around [child].
  final EdgeInsetsGeometry? padding;

  /// When non-null the entire panel becomes tappable.
  final VoidCallback? onTap;

  /// Corner radius. Defaults to 20.
  final double radius;

  /// When supplied, replaces the flat hairline border with a gradient stroke.
  final Gradient? borderGradient;

  /// Backdrop blur sigma. Larger values read as thicker glass.
  final double blur;

  /// Whether the 1px top-edge highlight is painted.
  final bool showHighlight;

  /// Optional semantics label describing the whole panel.
  final String? semanticLabel;

  /// The panel content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final borderRadius = BorderRadius.circular(radius);

    Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    if (onTap != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          splashColor: c.accent.withValues(alpha: 0.10),
          highlightColor: c.accent.withValues(alpha: 0.06),
          child: content,
        ),
      );
    }

    Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.72),
        borderRadius: borderRadius,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: c.glass, borderRadius: borderRadius),
        child: CustomPaint(
          foregroundPainter: _GlassEdgePainter(
            radius: radius,
            borderColor: c.hairline,
            borderGradient: borderGradient,
            highlightColor: showHighlight
                ? c.textPrimary.withValues(alpha: 0.12)
                : null,
          ),
          child: content,
        ),
      ),
    );

    panel = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: panel,
      ),
    );

    final label = semanticLabel;
    if (label != null) {
      panel = Semantics(
        label: label,
        container: true,
        button: onTap != null,
        child: panel,
      );
    }
    return panel;
  }
}

/// Wraps [child] in a gradient-stroked rounded border.
///
/// Unlike a [Container] decoration this strokes the border *inside* the
/// bounds, so the stroke never bleeds into neighbouring layout and can follow
/// any [Gradient] - including a sweep or a multi-stop shader.
class GradientBorder extends StatelessWidget {
  /// Creates a gradient border around [child].
  const GradientBorder({
    super.key,
    required this.gradient,
    this.radius = 20,
    this.strokeWidth = 1,
    this.padding = EdgeInsets.zero,
    this.backgroundColor,
    required this.child,
  });

  /// The gradient painted along the border.
  final Gradient gradient;

  /// Corner radius of the stroked rounded rectangle.
  final double radius;

  /// Stroke thickness in logical pixels.
  final double strokeWidth;

  /// Optional padding between the border and [child].
  final EdgeInsetsGeometry padding;

  /// Optional fill painted underneath [child].
  final Color? backgroundColor;

  /// The wrapped content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget content = padding == EdgeInsets.zero
        ? child
        : Padding(padding: padding, child: child);

    Widget bordered = CustomPaint(
      foregroundPainter: _GlassEdgePainter(
        radius: radius,
        borderGradient: gradient,
        strokeWidth: strokeWidth,
      ),
      child: content,
    );

    final fill = backgroundColor;
    if (fill != null) {
      bordered = DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: bordered,
      );
    }
    return bordered;
  }
}

/// A transparent, blurred app bar that materialises as the user scrolls.
///
/// Feed it the current scroll offset through [scrollOffset]; at 0 the bar is
/// fully transparent, and by roughly 64 logical pixels the backdrop blur, tint
/// and bottom hairline have faded all the way in.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Creates a glass app bar.
  const GlassAppBar({
    super.key,
    this.title,
    this.leading,
    this.actions,
    this.bottom,
    this.scrollOffset = 0,
    this.toolbarHeight = kToolbarHeight,
    this.blur = 20,
    this.centerTitle = false,
    this.tint,
  });

  /// The primary widget displayed in the bar.
  final Widget? title;

  /// A widget to display before [title].
  final Widget? leading;

  /// Widgets to display after [title].
  final List<Widget>? actions;

  /// A preferred-size widget displayed along the bottom edge.
  final PreferredSizeWidget? bottom;

  /// Current scroll offset of the content behind the bar.
  final double scrollOffset;

  /// Height of the toolbar row. Defaults to [kToolbarHeight].
  final double toolbarHeight;

  /// Maximum backdrop blur sigma once fully scrolled.
  final double blur;

  /// Whether [title] is centred.
  final bool centerTitle;

  /// Colour used for the frosted veil. Defaults to [ArcanumColors.canvas].
  final Color? tint;

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final double t = (scrollOffset / 64).clamp(0.0, 1.0).toDouble();
    final veil = (tint ?? c.canvas).withValues(alpha: 0.78 * t);

    Widget backdrop = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: veil,
        border: Border(
          bottom: BorderSide(color: c.hairline.withValues(alpha: t)),
        ),
      ),
    );
    if (t > 0.01) {
      backdrop = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur * t, sigmaY: blur * t),
        child: backdrop,
      );
    }

    return AppBar(
      toolbarHeight: toolbarHeight,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: centerTitle,
      title: title,
      leading: leading,
      actions: actions,
      bottom: bottom,
      flexibleSpace: ClipRect(child: backdrop),
    );
  }
}

/// Paints the 1px hairline (or gradient) border and the top-edge highlight.
class _GlassEdgePainter extends CustomPainter {
  const _GlassEdgePainter({
    required this.radius,
    this.borderColor,
    this.borderGradient,
    this.highlightColor,
    this.strokeWidth = 1,
  });

  final double radius;
  final Color? borderColor;
  final Gradient? borderGradient;
  final Color? highlightColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(inset),
      Radius.circular(math.max(0, radius - inset)),
    );

    final gradient = borderGradient;
    if (gradient != null) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..isAntiAlias = true
          ..shader = gradient.createShader(rect),
      );
    } else {
      final color = borderColor;
      if (color != null) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..isAntiAlias = true
            ..color = color,
        );
      }
    }

    final highlight = highlightColor;
    if (highlight != null && size.height > strokeWidth) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, size.width, strokeWidth));
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..isAntiAlias = true
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: <Color>[
              highlight.withValues(alpha: 0),
              highlight,
              highlight.withValues(alpha: 0),
            ],
            stops: const <double>[0.0, 0.5, 1.0],
          ).createShader(rect),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.borderColor != borderColor ||
      oldDelegate.borderGradient != borderGradient ||
      oldDelegate.highlightColor != highlightColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
