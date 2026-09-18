import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import 'delta_chip.dart';
import 'glass.dart';

/// A titled section divider used at the top of every list group.
class SectionHeader extends StatelessWidget {
  /// Creates a section header.
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(20, 24, 20, 12),
  });

  /// The section title.
  final String title;

  /// Optional supporting line rendered beneath [title].
  final String? subtitle;

  /// Optional widget pinned to the trailing edge, typically a text button.
  final Widget? trailing;

  /// Outer padding. Defaults to `EdgeInsets.fromLTRB(20, 24, 20, 12)`.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final subtitle = this.subtitle;
    final trailing = this.trailing;

    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.titleLarge,
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.bodySmall?.copyWith(color: c.textTertiary),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing,
          ],
        ],
      ),
    );
  }
}

/// A friendly centred placeholder for empty lists and failed loads.
class EmptyState extends StatelessWidget {
  /// Creates an empty state.
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  });

  /// The glyph shown inside the radial glow.
  final IconData icon;

  /// The headline.
  final String title;

  /// Optional supporting copy.
  final String? message;

  /// Optional call to action rendered below the copy.
  final Widget? action;

  /// Tightens the glow and spacing for use inside cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final message = this.message;
    final action = this.action;
    final glow = compact ? 84.0 : 120.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: compact ? 20 : 36,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: glow,
            height: glow,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    c.accent.withValues(alpha: 0.22),
                    c.accent.withValues(alpha: 0),
                  ],
                ),
              ),
              child: Center(
                child: Icon(icon, size: compact ? 28 : 38, color: c.accent),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.t.titleMedium,
          ),
          // A sentence four hundred pixels long is comfortable; one fourteen
          // hundred pixels long is not, because the eye loses the start of the
          // next line on the way back. A desktop window is wider than any
          // sentence needs, so the copy is capped rather than stretched to the
          // edge - capped here rather than around the column, because the
          // column is stretched to the window by whatever holds it and a cap
          // outside it would simply be overruled.
          if (message != null) ...<Widget>[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _readingWidth),
              child: Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: context.t.bodySmall?.copyWith(
                  color: c.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
          if (action != null) ...<Widget>[const SizedBox(height: 18), action],
        ],
      ),
    );
  }

  /// How wide a line of supporting copy is allowed to run.
  static const double _readingWidth = 560;
}

/// A dashboard metric tile: small label, big numeric value and optional delta.
class StatTile extends StatelessWidget {
  /// Creates a statistic tile.
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.icon,
    this.caption,
    this.valueColor,
    this.onTap,
    this.semanticLabel,
  });

  /// Small uppercase-ish label above the value.
  final String label;

  /// The headline value, already formatted.
  final String value;

  /// Optional signed percentage change rendered as a [DeltaChip].
  final double? delta;

  /// Optional leading glyph beside [label].
  final IconData? icon;

  /// Optional trailing caption rendered next to the delta.
  final String? caption;

  /// Optional override for the value colour.
  final Color? valueColor;

  /// When non-null the whole tile becomes tappable.
  final VoidCallback? onTap;

  /// Optional semantics override.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final icon = this.icon;
    final delta = this.delta;
    final caption = this.caption;
    final radius = BorderRadius.circular(18);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 15, color: c.textTertiary),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: context.t.headlineSmall?.copyWith(
              color: valueColor ?? c.textPrimary,
            ),
          ),
        ),
        if (delta != null || caption != null) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              if (delta != null) DeltaChip(percent: delta, compact: true),
              if (delta != null && caption != null) const SizedBox(width: 8),
              if (caption != null)
                Expanded(
                  child: Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );

    Widget content = Padding(padding: const EdgeInsets.all(14), child: body);
    if (onTap != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, borderRadius: radius, child: content),
      );
    }

    Widget tile = DecoratedBox(
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: radius,
        border: Border.all(color: c.hairline),
      ),
      child: content,
    );

    final label2 = semanticLabel;
    if (label2 != null) {
      tile = Semantics(
        label: label2,
        container: true,
        button: onTap != null,
        child: tile,
      );
    }
    return tile;
  }
}

/// An animated shimmer block used as a loading placeholder.
///
/// Implemented with a plain [AnimationController] and a swept [LinearGradient]
/// - no third-party shimmer package required. When [width] is null the block
/// expands to fill the available width, so it must live inside a bounded box.
class LoadingShimmer extends StatefulWidget {
  /// Creates a shimmer block.
  const LoadingShimmer({
    super.key,
    this.width,
    this.height = 16,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.semanticLabel,
  });

  /// Width in logical pixels. Null expands to the available width.
  final double? width;

  /// Height in logical pixels.
  final double height;

  /// Corner radius of the block.
  final BorderRadius borderRadius;

  /// Optional semantics label.
  final String? semanticLabel;

  @override
  State<LoadingShimmer> createState() => _LoadingShimmerState();
}

class _LoadingShimmerState extends State<LoadingShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final base = c.surfaceRaised;
    final highlight = Color.alphaBlend(c.glass, base);

    return Semantics(
      label: widget.semanticLabel ?? 'Loading',
      excludeSemantics: true,
      child: SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            final a = -1.4 + 2.8 * _controller.value;
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: widget.borderRadius,
                gradient: LinearGradient(
                  begin: Alignment(a, 0),
                  end: Alignment(a + 0.7, 0),
                  colors: <Color>[base, highlight, base],
                  stops: const <double>[0.0, 0.5, 1.0],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Renders a Riverpod [AsyncValue] as loading / error / empty / data.
class AsyncValueView<T> extends StatelessWidget {
  /// Creates an async value view.
  const AsyncValueView({
    super.key,
    required this.value,
    required this.builder,
    this.loading,
    this.emptyMessage,
    this.isEmpty,
    this.onRetry,
    this.errorTitle = 'Something went wrong',
    this.loadingHeight = 120,
    this.emptyIcon = Icons.inbox_rounded,
  });

  /// The value to render.
  final AsyncValue<T> value;

  /// Builds the success case.
  final Widget Function(T data) builder;

  /// Optional custom loading widget. Defaults to a [LoadingShimmer] block.
  final Widget? loading;

  /// Message shown when [isEmpty] reports an empty payload. When null, an
  /// empty payload renders nothing.
  final String? emptyMessage;

  /// Predicate deciding whether [T] counts as empty.
  final bool Function(T data)? isEmpty;

  /// Called when the user taps "Retry" on the error card.
  final VoidCallback? onRetry;

  /// Headline shown on the error card.
  final String errorTitle;

  /// Height of the default loading shimmer.
  final double loadingHeight;

  /// Icon used by the empty state.
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    final async = value;

    if (async.hasValue) {
      final data = async.value as T;
      final empty = isEmpty?.call(data) ?? false;
      if (empty) {
        final message = emptyMessage;
        if (message == null) return const SizedBox.shrink();
        return EmptyState(icon: emptyIcon, title: message, compact: true);
      }
      return builder(data);
    }

    if (async.hasError) {
      return _ErrorCard(
        title: errorTitle,
        message: '${async.error}',
        onRetry: onRetry,
      );
    }

    return loading ??
        LoadingShimmer(
          height: loadingHeight,
          borderRadius: BorderRadius.circular(20),
        );
  }
}

/// The friendly retry card shown by [AsyncValueView] on failure.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.title, required this.message, this.onRetry});

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final onRetry = this.onRetry;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, size: 18, color: c.negative),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A segmented pill control with an animated selection indicator.
class PillToggle extends StatelessWidget {
  /// Creates a segmented pill toggle.
  const PillToggle({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.height = 38,
    this.padding = const EdgeInsets.all(4),
    this.semanticLabel,
  });

  /// The segment labels, left to right.
  final List<String> options;

  /// Index of the selected segment.
  final int selected;

  /// Called with the new index when a segment is tapped.
  final ValueChanged<int> onChanged;

  /// Overall height of the control.
  final double height;

  /// Padding between the outer pill and the segments.
  final EdgeInsets padding;

  /// Optional semantics label for the whole control.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (options.isEmpty) return const SizedBox.shrink();

    final index = selected.clamp(0, options.length - 1);
    final innerHeight = math.max(0.0, height - padding.vertical);
    final segmentRadius = BorderRadius.circular(innerHeight / 2);
    final indicatorColor = c.accentSoft;

    final segments = <Widget>[
      for (var i = 0; i < options.length; i++)
        Expanded(
          child: Semantics(
            button: true,
            selected: i == index,
            label: options[i],
            excludeSemantics: true,
            child: InkWell(
              onTap: () => onChanged(i),
              borderRadius: segmentRadius,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      options[i],
                      maxLines: 1,
                      style:
                          (i == index
                                  ? context.t.labelLarge
                                  : context.t.labelMedium)
                              ?.copyWith(
                                color: i == index
                                    ? c.textPrimary
                                    : c.textSecondary,
                              ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final maxWidth = constraints.maxWidth;
        final bounded = maxWidth.isFinite && maxWidth > 0;
        final segmentWidth = bounded
            ? (maxWidth - padding.horizontal) / options.length
            : 0.0;

        Widget bar = Row(children: segments);
        if (bounded && segmentWidth > 0) {
          bar = Stack(
            children: <Widget>[
              bar,
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: padding.left + segmentWidth * index,
                top: padding.top,
                width: segmentWidth,
                height: innerHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: segmentRadius,
                    border: Border.all(color: c.accent.withValues(alpha: 0.45)),
                  ),
                ),
              ),
            ],
          );
        }

        Widget control = Padding(
          padding: padding,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(innerHeight),
            child: Material(type: MaterialType.transparency, child: bar),
          ),
        );

        final label = semanticLabel;
        if (label != null) {
          control = Semantics(label: label, container: true, child: control);
        }

        return SizedBox(
          height: height,
          width: bounded ? maxWidth : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.surfaceRaised,
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(color: c.hairline),
            ),
            child: control,
          ),
        );
      },
    );
  }
}
