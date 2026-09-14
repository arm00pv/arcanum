import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/quant/quant.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// How far ahead the audit's predictions reach.
enum _Horizon {
  /// Seven days out: the horizon with the most testable history.
  week(
    'A week',
    7,
    'Seven days out. The most history to test, so the most to go on.',
  ),

  /// The horizon the card screen quotes.
  month(
    'A month',
    30,
    'The horizon the card screen quotes when it shows a forecast.',
  ),

  /// A quarter, which is as far as most price series reach.
  quarter(
    'A quarter',
    90,
    'Long enough for a trend to matter, and the thinnest of the three.',
  );

  const _Horizon(this.label, this.days, this.note);

  /// The pill label.
  final String label;

  /// How many days ahead the prediction reaches.
  final int days;

  /// One line describing what that horizon means.
  final String note;
}

/// Holds the app's own forecast to what actually happened.
///
/// The card screen prints a trend reading and a forecast with bands; this page
/// rewinds both over the price history this phone recorded, judges every
/// prediction against the price that followed it, and compares the result with
/// what knowing nothing would have scored. It is the only screen in Arcanum
/// that is allowed to say the forecast is not very good.
class ForecastAuditScreen extends ConsumerStatefulWidget {
  /// Creates the audit screen.
  const ForecastAuditScreen({super.key});

  @override
  ConsumerState<ForecastAuditScreen> createState() =>
      _ForecastAuditScreenState();
}

class _ForecastAuditScreenState extends ConsumerState<ForecastAuditScreen> {
  late CardGame _game;
  _Horizon _horizon = _Horizon.month;

  @override
  void initState() {
    super.initState();
    _game = ref.read(activeGameProvider);
  }

  @override
  Widget build(BuildContext context) {
    final ForecastAuditKey key = (game: _game, horizonDays: _horizon.days);
    final AsyncValue<ForecastAudit> audit = ref.watch(
      forecastAuditProvider(key),
    );
    final AsyncValue<Map<String, TcgCard>> cards = ref.watch(
      ownedCardsProvider(_game),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Forecast accuracy', style: context.t.headlineSmall),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: <Widget>[
          const SectionHeader(
            title: 'What to test',
            subtitle: "The app's own reading, held to what happened",
          ),
          _picker(),
          AsyncValueView<ForecastAudit>(
            value: audit,
            loading: _running(),
            errorTitle: 'The audit could not run',
            onRetry: () => ref.invalidate(forecastAuditProvider(key)),
            builder: (ForecastAudit data) => _body(data, cards),
          ),
        ],
      ),
    );
  }

  Widget _picker() {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Collection', style: context.t.titleSmall),
          const SizedBox(height: 10),
          PillToggle(
            options: <String>[
              for (final CardGame game in CardGame.values) game.shortLabel,
            ],
            selected: CardGame.values.indexOf(_game),
            semanticLabel: 'Which collection to test',
            onChanged: (int index) =>
                setState(() => _game = CardGame.values[index]),
          ),
          const SizedBox(height: 18),
          Text('How far ahead', style: context.t.titleSmall),
          const SizedBox(height: 10),
          PillToggle(
            options: <String>[
              for (final _Horizon horizon in _Horizon.values) horizon.label,
            ],
            selected: _Horizon.values.indexOf(_horizon),
            semanticLabel: 'How far ahead the predictions reach',
            onChanged: (int index) =>
                setState(() => _horizon = _Horizon.values[index]),
          ),
          const SizedBox(height: 10),
          Text(
            _horizon.note,
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 6),
          Text(
            'Every prediction on this page was made by a model that could see '
            'only the prices recorded before it, and is judged against the '
            'price that followed.',
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }

  /// What is happening while the arithmetic runs.
  Widget _running() => _group(
    child: Row(
      children: <Widget>[
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Rewinding the model', style: context.t.titleSmall),
              const SizedBox(height: 2),
              Text(
                'Every prediction refits the forecast the card screen would '
                'have shown, so this takes a moment on a large collection.',
                style: context.t.labelSmall?.copyWith(
                  color: context.c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _body(ForecastAudit audit, AsyncValue<Map<String, TcgCard>> cards) {
    if (audit.overall.trials == 0) return _nothingYet(audit);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader(title: 'What came out'),
        _verdict(audit),
        const SectionHeader(title: 'The figures'),
        _rows(audit.summary),
        if (audit.cards.isNotEmpty) ...<Widget>[
          const SectionHeader(
            title: 'The cards tested',
            subtitle: 'The printings with the most predictions behind them',
          ),
          _cardRows(audit, cards),
        ],
        const SectionHeader(
          title: 'What this does not prove',
          subtitle: 'The parts the figures cannot reach',
        ),
        _bullets(audit.caveats),
        _footnote(audit),
      ],
    );
  }

  /// The headline, and the sentence that keeps it honest.
  Widget _verdict(ForecastAudit audit) {
    final c = context.c;
    final ForecastScore score = audit.overall;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                audit.thinData
                    ? Icons.help_outline_rounded
                    : Icons.insights_rounded,
                size: 20,
                color: audit.thinData ? c.textTertiary : c.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(audit.headline, style: context.t.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _verdictText(audit),
            style: context.t.bodySmall?.copyWith(
              color: c.textSecondary,
              height: 1.45,
            ),
          ),
          if (score.trials > 0) ...<Widget>[
            const SizedBox(height: 14),
            _bar(score),
          ],
        ],
      ),
    );
  }

  /// Three bars: the reading, and the two things that know nothing.
  Widget _bar(ForecastScore score) {
    final c = context.c;
    return Column(
      children: <Widget>[
        _barRow('The reading', score.readingHitRate ?? 0, c.accent),
        const SizedBox(height: 6),
        _barRow(
          'Always calling it ${score.commonest.$1.label}',
          score.majorityHitRate ?? 0,
          c.textTertiary,
        ),
        const SizedBox(height: 6),
        _barRow(
          'Guessing blind',
          kChanceHitRate,
          c.textTertiary.withValues(alpha: 0.5),
        ),
      ],
    );
  }

  Widget _barRow(String label, double fraction, Color colour) => Row(
    children: <Widget>[
      SizedBox(
        width: 128,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.t.labelSmall?.copyWith(color: context.c.textSecondary),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: context.c.surfaceRaised,
            valueColor: AlwaysStoppedAnimation<Color>(colour),
          ),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 44,
        child: Text(
          Fmt.percentPlain(fraction * 100),
          textAlign: TextAlign.right,
          style: context.t.labelSmall,
        ),
      ),
    ],
  );

  String _verdictText(ForecastAudit audit) {
    final ForecastScore score = audit.overall;
    final double? rate = score.readingHitRate;
    if (rate == null) {
      return 'Nothing could be predicted, so nothing is claimed.';
    }
    final (double low, double high) = score.readingInterval ?? (0, 0);
    final StringBuffer text = StringBuffer()
      ..write(
        'Across ${Fmt.count(score.trials)} predictions on '
        '${Fmt.count(audit.cardsTested)} cards, the trend the card screen would '
        'have shown pointed the right way ${Fmt.percentPlain(rate * 100)} of '
        'the time, in a range of ${Fmt.percentPlain(low * 100)} to '
        '${Fmt.percentPlain(high * 100)}. ',
      );
    final double? majority = score.majorityHitRate;
    if (majority != null) {
      text.write(
        'Always calling it ${score.commonest.$1.label} would have scored '
        '${Fmt.percentPlain(majority * 100)}, and guessing blind would have '
        'scored ${Fmt.percentPlain(kChanceHitRate * 100)}. ',
      );
    }
    final double? number = score.numberHitRate;
    if (number != null) {
      text.write(
        'The forecast number itself pointed the right way '
        '${Fmt.percentPlain(number * 100)} of the time. ',
      );
    }
    final double? majorityGap = audit.edgeOverMajority;
    if (majorityGap != null) {
      text.write(
        majorityGap >= 0
            ? 'That is ${_points(majorityGap)} better than a rule that looks at '
                  'nothing. '
            : 'That is ${_points(-majorityGap)} worse than a rule that looks at '
                  'nothing. ',
      );
    }
    final double? median = score.medianAbsoluteErrorPct;
    final double? naiveMedian = score.naiveMedianAbsoluteErrorPct;
    if (median != null && naiveMedian != null) {
      text.write(
        'Its typical miss was ${median.toStringAsFixed(2)}% of the price, '
        'against ${naiveMedian.toStringAsFixed(2)}% for assuming the price would '
        'not move.',
      );
    }
    if (score.hasRunaways) {
      text.write(
        ' ${score.aimedTooHigh + score.aimedTooLow} of those predictions left '
        'the credible range entirely, which is why the average miss is so much '
        'larger than the typical one.',
      );
    }
    if (audit.thinData) {
      text.write(
        ' That is too few predictions to settle anything, and this page would '
        'rather say so than dress it up.',
      );
    }
    return text.toString();
  }

  /// A rate difference as whole percentage points.
  static String _points(double fraction) =>
      '${(fraction * 100).toStringAsFixed(0)} points';

  Widget _nothingYet(ForecastAudit audit) => EmptyState(
    icon: Icons.timeline_rounded,
    title: 'Nothing to test yet',
    message:
        '${Fmt.count(audit.cardsOffered)} printings in this collection have '
        'prices recorded, and not one of them reaches the '
        '${audit.minTrainingDays} days a ${audit.horizonDays}-day prediction '
        'needs before it can be judged. History builds up on its own every day '
        'you open Arcanum.',
  );

  Widget _cardRows(
    ForecastAudit audit,
    AsyncValue<Map<String, TcgCard>> cards,
  ) {
    final c = context.c;
    final Map<String, TcgCard> owned = cards.hasValue
        ? cards.value as Map<String, TcgCard>
        : const <String, TcgCard>{};
    final List<CardBacktest> rows = audit.cards.take(15).toList();
    return _group(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: <Widget>[
          for (final CardBacktest row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          owned[row.cardId]?.name ?? row.cardId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodyMedium,
                        ),
                        Text(
                          '${Fmt.count(row.score.trials)} predictions · typical '
                          'miss '
                          '${row.score.medianAbsoluteErrorPct?.toStringAsFixed(2) ?? '--'}%',
                          style: context.t.labelSmall?.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    row.score.readingHitRate == null
                        ? '--'
                        : '${Fmt.percentPlain(row.score.readingHitRate! * 100)}'
                              ' right',
                    style: context.t.titleSmall,
                  ),
                ],
              ),
            ),
          if (audit.cards.length > rows.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'and ${Fmt.count(audit.cards.length - rows.length)} more cards '
                'were tested.',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rows(List<(String, String)> rows) => _group(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String label, String value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: context.t.bodySmall?.copyWith(
                      color: context.c.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(value, style: context.t.titleSmall),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _bullets(List<String> notes) {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String note in notes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: 8),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.textTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      note,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _footnote(ForecastAudit audit) {
    final c = context.c;
    final DateTime? from = audit.earliestPrediction;
    final DateTime? to = audit.latestPrediction;
    final String span = from == null || to == null
        ? ''
        : ' The predictions here were aimed between ${Fmt.date(from)} and '
              '${Fmt.date(to)}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Text(
        'Prices are the ones Arcanum records and backfills itself, one series '
        'per printing; a card with no recorded history is not in this audit at '
        'all, which is why fewer cards are tested than you own.$span',
        style: context.t.labelSmall?.copyWith(color: c.textTertiary),
      ),
    );
  }

  /// A grouped glass block: 20px radius, 16px padding, 20px page gutters.
  Widget _group({required Widget child, EdgeInsetsGeometry? padding}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          radius: 20,
          padding: padding ?? const EdgeInsets.all(16),
          child: child,
        ),
      );
}
