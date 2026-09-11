import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/price_alert.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// Manages standing price alerts for the active game.
///
/// Every rival tracker either has no alerts at all or buries them; the research
/// for this app found them essentially absent from the category. They are
/// evaluated on-device against the daily market prices the app already holds,
/// so there is no server, no push infrastructure and no account involved.
class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  final _scrollController = ScrollController();
  double _scrollOffset = 0;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final o = _scrollController.offset;
      if ((o - _scrollOffset).abs() > 4) setState(() => _scrollOffset = o);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _checkNow(CardGame game) async {
    setState(() => _checking = true);
    try {
      final alerts = await ref.read(alertsProvider(game).future);
      final ids = alerts.map((a) => a.cardId).toSet().toList();
      if (ids.isNotEmpty) {
        // Pull fresh market prices first, then re-evaluate.
        await ref.read(catalogRepositoryProvider).refreshPrices(game, ids);
      }
      ref.invalidate(alertRevisionProvider);
      final fired = await ref.read(alertEvaluationProvider.future);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(fired.isEmpty
                ? 'Checked ${alerts.length} alerts — nothing triggered'
                : '${fired.length} alert${fired.length == 1 ? '' : 's'} triggered'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not check: $e')));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final alertsAsync = ref.watch(alertsProvider(game));
    final cards = ref.watch(alertCardsProvider(game)).value ?? const <String, TcgCard>{};

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration:
                  BoxDecoration(gradient: AppTheme.backdrop(c, tint: game.accent)),
            ),
          ),
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: GlassAppBar(
                  scrollOffset: _scrollOffset,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Alerts', style: context.t.headlineMedium),
                      Text(
                        '${game.shortLabel} · checked against daily market prices',
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                  actions: [
                    IconButton(
                      tooltip: 'Check now',
                      onPressed: _checking ? null : () => _checkNow(game),
                      icon: _checking
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: game.accent,
                              ),
                            )
                          : const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
              SliverAsyncView<List<PriceAlert>>(
                value: alertsAsync,
                loadingHeight: 320,
                onRetry: () => ref.invalidate(alertsProvider(game)),
                isEmpty: (a) => a.isEmpty,
                emptyTitle: 'No alerts yet',
                emptyMessage:
                    'Open any card and tap the bell to be told when its price '
                    'moves past a number you care about.',
                builder: (alerts) {
                  final fired = alerts.where((a) => !a.isArmed).toList();
                  final armed = alerts.where((a) => a.isArmed).toList();

                  Future<void> refresh() async {
                    ref.invalidate(alertRevisionProvider);
                    ref.invalidate(alertsProvider(game));
                  }

                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
                    sliver: SliverList.list(
                      children: [
                        if (fired.isNotEmpty) ...[
                          SectionHeader(
                            title: 'Triggered',
                            subtitle: '${fired.length} '
                                '${fired.length == 1 ? 'alert has' : 'alerts have'} fired',
                            padding: const EdgeInsets.only(bottom: 10),
                          ),
                          for (var i = 0; i < fired.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _AlertCard(
                                alert: fired[i],
                                card: cards[fired[i].cardId],
                                index: i,
                                onChanged: refresh,
                              ),
                            ),
                          const SizedBox(height: 14),
                        ],
                        if (armed.isNotEmpty) ...[
                          SectionHeader(
                            title: 'Armed',
                            subtitle: 'Watching ${armed.length} '
                                '${armed.length == 1 ? 'printing' : 'printings'}',
                            padding: const EdgeInsets.only(bottom: 10),
                          ),
                          for (var i = 0; i < armed.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _AlertCard(
                                alert: armed[i],
                                card: cards[armed[i].cardId],
                                index: i,
                                onChanged: refresh,
                              ),
                            ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends ConsumerWidget {
  const _AlertCard({
    required this.alert,
    required this.card,
    required this.index,
    required this.onChanged,
  });

  final PriceAlert alert;
  final TcgCard? card;
  final int index;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final game = alert.game;
    final current = card?.prices.priceFor(alert.effectiveFinish) ?? card?.prices.from;
    final progress = alert.progress(current);
    final fired = !alert.isArmed;

    return GlassCard(
      padding: EdgeInsets.zero,
      borderGradient: fired
          ? LinearGradient(colors: [
              c.warning.withValues(alpha: 0.9),
              c.warning.withValues(alpha: 0.15),
            ])
          : null,
      onTap: card == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CardDetailScreen(game: game, cardId: card!.id),
                ),
              ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 44,
                  child: CardThumbnail(
                    imageUrl: card?.imageUrl(size: 'small'),
                    width: 44,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card?.name ?? alert.cardName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (card != null)
                            '${card!.setCode.toUpperCase()} #${card!.collectorNumber}',
                          alert.effectiveFinish.shortLabel,
                          alert.describe(),
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      current == null ? '--' : Fmt.money(current),
                      style: context.t.titleSmall,
                    ),
                    Text(
                      fired ? 'triggered' : 'watching',
                      style: context.t.labelSmall?.copyWith(
                        color: fired ? c.warning : c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress ?? 0,
                minHeight: 5,
                backgroundColor: c.surfaceRaised,
                valueColor: AlwaysStoppedAnimation(
                  fired ? c.warning : game.accent,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (alert.baseline != null)
                  Text(
                    'armed at ${Fmt.moneyAdaptive(alert.baseline)}',
                    style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    await ref.read(alertRepositoryProvider).rearm(alert, card);
                    await onChanged();
                  },
                  icon: const Icon(Icons.restart_alt_rounded, size: 16),
                  label: Text(fired ? 'Re-arm' : 'Rebase'),
                ),
                IconButton(
                  tooltip: 'Delete alert',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    if (alert.id != null) {
                      await ref.read(alertRepositoryProvider).delete(alert.id!);
                    }
                    await onChanged();
                  },
                  icon: Icon(Icons.delete_outline_rounded, size: 18, color: c.textTertiary),
                ),
              ],
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 200.ms, delay: (index.clamp(0, 12) * 20).ms);
  }
}

/// Opens the "create an alert" sheet for a printing.
Future<bool> showSetAlertSheet(
  BuildContext context,
  WidgetRef ref,
  TcgCard card, {
  CardFinish? initialFinish,
}) async {
  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SetAlertSheet(card: card, initialFinish: initialFinish),
  );
  if (created == true) {
    ref.read(alertRevisionProvider.notifier).bump();
  }
  return created ?? false;
}

class _SetAlertSheet extends ConsumerStatefulWidget {
  const _SetAlertSheet({required this.card, this.initialFinish});

  final TcgCard card;
  final CardFinish? initialFinish;

  @override
  ConsumerState<_SetAlertSheet> createState() => _SetAlertSheetState();
}

class _SetAlertSheetState extends ConsumerState<_SetAlertSheet> {
  late final CardFinish _finish =
      widget.initialFinish ?? widget.card.game.finishes.first;
  AlertKind _kind = AlertKind.above;
  late final TextEditingController _threshold;

  @override
  void initState() {
    super.initState();
    final current = _current;
    // Pre-fill with a sensible move: +10% for percentage rules, and a round
    // number near the current price for absolute ones.
    final seed = _kind.isPercent
        ? 10.0
        : (current == null ? 0.0 : (current * 1.1).ceilToDouble());
    _threshold = TextEditingController(
      text: seed == 0 ? '' : seed.toStringAsFixed(seed % 1 == 0 ? 0 : 2),
    );
  }

  @override
  void dispose() {
    _threshold.dispose();
    super.dispose();
  }

  double? get _current =>
      widget.card.prices.priceFor(_finish) ?? widget.card.prices.from;

  PriceAlert get _draft => PriceAlert(
        game: widget.card.game,
        cardId: widget.card.id,
        finish: _finish,
        kind: _kind,
        threshold: double.tryParse(_threshold.text.trim()) ?? 0,
        createdAt: DateTime.now(),
        baseline: _current,
      );

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = widget.card.game;
    final current = _current;
    final threshold = double.tryParse(_threshold.text.trim()) ?? 0;
    final evaluation = ref
        .read(alertRepositoryProvider)
        .preview(_draft, current);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: c.hairline),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.hairlineStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Icon(Icons.notifications_active_outlined, color: game.accent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Set a price alert', style: context.t.headlineSmall),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.card.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.bodySmall,
              ),
              const SizedBox(height: 18),

              Text(
                'WHEN',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in AlertKind.values)
                    _Chip(
                      label: k.isPercent ? k.label : k.label,
                      selected: _kind == k,
                      onTap: () => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: 18),

              Text(
                _kind.isPercent ? 'PERCENTAGE' : 'TARGET PRICE',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _threshold,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixText: _kind.isPercent ? null : r'$ ',
                  suffixText: _kind.isPercent ? '%' : null,
                  hintText: _kind.isPercent ? '10' : '25.00',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),

              GlassCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Now', style: context.t.bodySmall),
                              const SizedBox(height: 2),
                              Text(
                                current == null ? '--' : Fmt.money(current),
                                style: context.t.titleMedium,
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _kind.isPercent ? 'Baseline' : 'Target',
                              style: context.t.bodySmall,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _kind.isPercent
                                  ? (current == null ? '--' : Fmt.money(current))
                                  : Fmt.money(threshold),
                              style: context.t.titleMedium,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      evaluation.triggered
                          ? 'This would fire immediately at the current price.'
                          : _kind.isPercent
                              ? 'You will be told when the price moves '
                                  '${threshold.toStringAsFixed(threshold % 1 == 0 ? 0 : 1)}% '
                                  'from ${Fmt.money(current)}.'
                              : 'You will be told when the price '
                                  '${_kind == AlertKind.above ? 'rises above' : 'falls below'} '
                                  '${Fmt.money(threshold)}.',
                      style: context.t.bodySmall?.copyWith(
                        color: evaluation.triggered ? c.warning : c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              FilledButton.icon(
                onPressed: threshold <= 0 || current == null
                    ? null
                    : () async {
                        await ref.read(alertRepositoryProvider).create(
                              card: widget.card,
                              kind: _kind,
                              threshold: threshold,
                              finish: _finish,
                            );
                        if (context.mounted) Navigator.of(context).pop(true);
                      },
                icon: const Icon(Icons.add_alert_rounded, size: 20),
                label: const Text('Set alert'),
              ),
              if (current == null) ...[
                const SizedBox(height: 8),
                Text(
                  'This printing has no market price yet, so an alert cannot be '
                  'evaluated.',
                  style: context.t.labelSmall?.copyWith(color: c.warning),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.accent.withValues(alpha: 0.22) : c.surfaceRaised,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected ? c.accent.withValues(alpha: 0.65) : c.hairline,
            ),
          ),
          child: Text(
            label,
            style: context.t.labelMedium?.copyWith(
              color: selected ? c.accent : c.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
