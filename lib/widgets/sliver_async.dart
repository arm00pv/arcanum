import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// The sliver-safe sibling of [AsyncValueView].
///
/// A viewport can only take slivers as children, and [AsyncValueView] wraps its
/// result in a [Semantics] box — which is not a sliver and would crash the
/// viewport. This variant returns slivers for every state, so it can be dropped
/// straight into a [CustomScrollView].
///
/// [builder] must return a sliver.
class SliverAsyncView<T> extends StatelessWidget {
  const SliverAsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.loadingHeight = 320,
    this.onRetry,
    this.isEmpty,
    this.emptyMessage,
    this.emptyIcon = Icons.inbox_rounded,
    this.emptyTitle = 'Nothing here yet',
    this.errorTitle = 'Something went wrong',
  });

  /// The asynchronous value to render.
  final AsyncValue<T> value;

  /// Builds the content. Must return a sliver.
  final Widget Function(T data) builder;

  /// Height of the placeholder shown while loading.
  final double loadingHeight;

  /// Invoked by the retry button on the error state.
  final VoidCallback? onRetry;

  /// Returns true when the data should be treated as empty.
  final bool Function(T data)? isEmpty;

  final String? emptyMessage;
  final IconData emptyIcon;
  final String emptyTitle;
  final String errorTitle;

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: (data) {
        if (isEmpty?.call(data) ?? false) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 60, 24, 120),
              child: EmptyState(
                icon: emptyIcon,
                title: emptyTitle,
                message: emptyMessage,
              ),
            ),
          );
        }
        return builder(data);
      },
      loading: () => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            children: [
              LoadingShimmer(height: loadingHeight * 0.42),
              const SizedBox(height: 12),
              LoadingShimmer(height: loadingHeight * 0.24),
              const SizedBox(height: 12),
              LoadingShimmer(height: loadingHeight * 0.24),
            ],
          ),
        ),
      ),
      error: (error, stack) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 60, 20, 120),
          child: GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Icon(Icons.cloud_off_rounded, size: 30, color: context.c.warning),
                const SizedBox(height: 12),
                Text(errorTitle, style: context.t.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.bodySmall,
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Try again'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
