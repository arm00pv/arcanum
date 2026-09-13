import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/decks/deck_analysis.dart';
import 'package:arcanum/domain/decks/deck_check.dart';
import 'package:arcanum/domain/decks/deck_roles.dart';
import 'package:arcanum/widgets/glass.dart';

/// What a deck is made of, read off its own cards.
///
/// The panel is deliberately shy. Where the app could not read enough of the
/// deck to say anything - cards missing from the catalogue, a game whose
/// wording it has no rules for - it says so in place of the missing part rather
/// than drawing a shape out of the cards it happened to understand.
class DeckAnalysisCard extends StatelessWidget {
  /// Creates the panel for one deck's reading.
  const DeckAnalysisCard({super.key, required this.analysis, this.onSuggest});

  /// The reading.
  final DeckAnalysis analysis;

  /// Opens the list of cards the collector owns that would fit. Null hides the
  /// button, which is what a deck with nothing in it wants.
  final VoidCallback? onSuggest;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final suggest = onSuggest;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.insights_rounded, size: 18, color: c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Deck analysis', style: context.t.titleSmall),
              ),
              if (suggest != null)
                TextButton.icon(
                  onPressed: suggest,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                  label: const Text('Suggest'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 32),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          if (analysis.size == 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Add cards and the shape of the deck fills in here.',
                style: context.t.bodySmall?.copyWith(color: c.textTertiary),
              ),
            )
          else ...<Widget>[
            const SizedBox(height: 12),
            _Curve(analysis: analysis),
            const SizedBox(height: 14),
            _Roles(analysis: analysis),
            if (analysis.types.isNotEmpty ||
                analysis.subtypes.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              _Tally(
                icon: Icons.category_outlined,
                label: 'Made of',
                entries: analysis.types.take(5).toList(),
              ),
              if (analysis.subtypes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _Tally(
                    icon: Icons.diversity_3_outlined,
                    label: 'Types',
                    entries: analysis.subtypes.take(5).toList(),
                  ),
                ),
            ],
            for (final issue in analysis.advice)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _Advice(issue: issue),
              ),
            if (analysis.rolesRead)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Roles are read from the words on the cards, so a card that '
                  'does its job oddly may be counted oddly.',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// The mana curve, as a row of bars.
class _Curve extends StatelessWidget {
  const _Curve({required this.analysis});

  final DeckAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (!analysis.curveRead) {
      return Text(
        'The curve needs mana values for most of the deck, and this one does '
        'not have them yet.',
        style: context.t.bodySmall?.copyWith(color: c.textTertiary),
      );
    }

    final curve = analysis.curve;
    var peak = 1;
    for (final int n in curve) {
      if (n > peak) peak = n;
    }
    final average = analysis.averageCost;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Both halves are flexible: at a large text setting a fixed-width pair
        // of labels would push each other off the edge of the panel.
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Mana curve',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
            if (average != null)
              Expanded(
                child: Text(
                  'average ${average.toStringAsFixed(1)}',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 52,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (int i = 0; i < curve.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        if (curve[i] > 0)
                          // Flexible and scaled down so a large text setting
                          // squeezes the label rather than the bar underneath
                          // it off the bottom of the chart.
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '${curve[i]}',
                                style: context.t.labelSmall?.copyWith(
                                  color: c.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 2),
                        Container(
                          height: 2 + 26 * (curve[i] / peak),
                          decoration: BoxDecoration(
                            color: curve[i] == 0
                                ? c.hairline
                                : c.accent.withValues(
                                    alpha: 0.35 + 0.65 * (curve[i] / peak),
                                  ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: <Widget>[
            for (int i = 0; i < curve.length; i++)
              Expanded(
                child: Text(
                  i == curve.length - 1 ? '$i+' : '$i',
                  textAlign: TextAlign.center,
                  style: context.t.labelSmall?.copyWith(
                    color: c.textTertiary,
                    fontSize: 9,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// How much of each job the deck has, against the usual starting point.
class _Roles extends StatelessWidget {
  const _Roles({required this.analysis});

  final DeckAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (!analysis.rolesRead) {
      return Text(
        'Not enough of this deck has rules text for the app to read what the '
        'cards do.',
        style: context.t.bodySmall?.copyWith(color: c.textTertiary),
      );
    }

    // Roles with a target come first, then anything else the deck actually
    // holds - a counterspell count is worth seeing even where no target is
    // offered, and a role with neither is not worth a line.
    final roles = <DeckRole>[
      ...kRoleTargetShare.keys,
      for (final role in DeckRole.values)
        if (!kRoleTargetShare.containsKey(role) &&
            (analysis.roleCounts[role] ?? 0) > 0)
          role,
    ];

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final role in roles) _RoleChip(role: role, analysis: analysis),
      ],
    );
  }
}

/// One role, as 'Removal 2/7'.
class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role, required this.analysis});

  final DeckRole role;
  final DeckAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final held = analysis.roleCounts[role] ?? 0;
    final target = analysis.roleTargets[role] ?? 0;

    final colour = switch ((held, target)) {
      (0, final int t) when t > 0 => c.negative,
      (final int h, final int t) when h >= t => c.positive,
      (_, final int t) when t > 0 => c.warning,
      _ => c.textSecondary,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Text.rich(
        TextSpan(
          style: context.t.labelSmall?.copyWith(color: c.textSecondary),
          children: <InlineSpan>[
            TextSpan(
              text: role.label,
              style: TextStyle(color: colour),
            ),
            TextSpan(
              text: target > 0 ? '  $held/$target' : '  $held',
              style: TextStyle(color: colour.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line of counts: 'Creature 24 · Instant 8'.
class _Tally extends StatelessWidget {
  const _Tally({
    required this.icon,
    required this.label,
    required this.entries,
  });

  final IconData icon;
  final String label;
  final List<MapEntry<String, int>> entries;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 13, color: c.textTertiary),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              children: <InlineSpan>[
                TextSpan(text: '$label  '),
                for (int i = 0; i < entries.length; i++) ...<InlineSpan>[
                  if (i > 0) const TextSpan(text: '  ·  '),
                  TextSpan(
                    text: entries[i].key,
                    style: TextStyle(color: c.textSecondary),
                  ),
                  TextSpan(text: ' ${entries[i].value}'),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One observation about the shape of the deck.
class _Advice extends StatelessWidget {
  const _Advice({required this.issue});

  final DeckIssue issue;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final colour = switch (issue.level) {
      DeckIssueLevel.error => c.negative,
      DeckIssueLevel.warning => c.warning,
      DeckIssueLevel.note => c.textSecondary,
    };
    final icon = switch (issue.level) {
      DeckIssueLevel.error => Icons.close_rounded,
      DeckIssueLevel.warning => Icons.priority_high_rounded,
      DeckIssueLevel.note => Icons.info_outline_rounded,
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: colour),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                issue.title,
                style: context.t.bodyMedium?.copyWith(color: colour),
              ),
              Text(
                issue.detail,
                style: context.t.bodySmall?.copyWith(color: c.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
