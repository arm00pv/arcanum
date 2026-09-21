import 'dart:ui' as ui;

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/delta_chip.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/mana_pips.dart';
import 'package:arcanum/widgets/sparkline.dart';
import 'package:arcanum/widgets/trend_gauge.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps [child] in a themed, bounded box so widgets can be pumped in
/// isolation. The width is finite so widgets that expand horizontally
/// (`Sparkline`, `LoadingShimmer`) behave exactly as they do in the app.
Widget _host(Widget child, {double width = 340, double textScale = 1}) {
  return MaterialApp(
    theme: AppTheme.build(dark: true),
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 340,
  double textScale = 1,
}) async {
  await tester.pumpWidget(_host(child, width: width, textScale: textScale));
  await tester.pump(const Duration(milliseconds: 40));
}

Future<void> _pumpAppBar(WidgetTester tester, double scrollOffset) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(
        appBar: GlassAppBar(
          title: const Text('Arcanum'),
          leading: const Icon(Icons.menu_rounded),
          actions: const <Widget>[Icon(Icons.search_rounded)],
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(28),
            child: SizedBox(height: 28, child: Text('Binder')),
          ),
          scrollOffset: scrollOffset,
        ),
        body: const SizedBox(height: 600),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 220));
}

void main() {
  group('GlassCard', () {
    testWidgets('renders padded content', (WidgetTester tester) async {
      await _pump(
        tester,
        const GlassCard(
          padding: EdgeInsets.all(12),
          child: Text('Vault value'),
        ),
      );
      expect(find.text('Vault value'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('supports a gradient border, label and tap', (
      WidgetTester tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        GlassCard(
          semanticLabel: 'Total value card',
          borderGradient: const LinearGradient(
            colors: <Color>[Color(0xFF8B6CF6), Color(0xFF3FD98A)],
          ),
          radius: 12,
          onTap: () => taps++,
          child: const SizedBox(width: 120, height: 60, child: Text('Tap me')),
        ),
      );
      await tester.tap(find.text('Tap me'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(taps, 1);
    });

    testWidgets('survives a zero radius and zero blur', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const GlassCard(
          radius: 0,
          blur: 0,
          showHighlight: false,
          child: Text('Flat'),
        ),
      );
      expect(find.text('Flat'), findsOneWidget);
    });
  });

  group('GradientBorder', () {
    testWidgets('strokes around its child', (WidgetTester tester) async {
      await _pump(
        tester,
        const GradientBorder(
          gradient: LinearGradient(
            colors: <Color>[Color(0xFF8B6CF6), Color(0xFFEE6C2D)],
          ),
          padding: EdgeInsets.all(10),
          strokeWidth: 2,
          child: Text('Framed'),
        ),
      );
      expect(find.text('Framed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('GlassAppBar', () {
    testWidgets('renders at rest and once scrolled', (
      WidgetTester tester,
    ) async {
      await _pumpAppBar(tester, 0);
      expect(find.text('Arcanum'), findsOneWidget);
      expect(find.text('Binder'), findsOneWidget);

      await _pumpAppBar(tester, 240);
      expect(find.text('Arcanum'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Sparkline', () {
    testWidgets('renders a normal series', (WidgetTester tester) async {
      await _pump(
        tester,
        const Sparkline(
          values: <double>[1, 4, 2, 8, 5, 9, 3],
          height: 56,
          baseline: 4,
        ),
      );
      expect(find.byType(Sparkline), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles empty, single and constant series', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const Sparkline(values: <double>[]));
      await _pump(tester, const Sparkline(values: <double>[42]));
      await _pump(tester, const Sparkline(values: <double>[7, 7, 7, 7]));
      await _pump(
        tester,
        const Sparkline(values: <double>[double.nan, 2, double.infinity]),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 2x text scale', (WidgetTester tester) async {
      await _pump(
        tester,
        const Sparkline(values: <double>[1, 2, 3, 4], height: 48),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SparklinePainter', () {
    test('paints every shape of series without throwing', () {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      const size = Size(140, 44);
      const color = Color(0xFF8B6CF6);
      final series = <List<double>>[
        <double>[],
        <double>[3],
        <double>[5, 5, 5, 5],
        <double>[1, 9, 3, 7, 2],
        <double>[double.nan, 4, double.infinity, -double.infinity],
        <double>[1e12, -1e12, 0],
      ];
      for (final values in series) {
        SparklinePainter(
          values: values,
          color: color,
          baseline: 2,
        ).paint(canvas, size);
      }
      expect(recorder.endRecording(), isNotNull);
    });

    test('shouldRepaint reacts to data and style changes', () {
      const color = Color(0xFF8B6CF6);
      final base = SparklinePainter(values: const <double>[1, 2], color: color);
      expect(
        base.shouldRepaint(
          SparklinePainter(values: const <double>[1, 2], color: color),
        ),
        isFalse,
      );
      expect(
        base.shouldRepaint(
          SparklinePainter(values: const <double>[1, 3], color: color),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          SparklinePainter(
            values: const <double>[1, 2],
            color: color,
            fill: false,
          ),
        ),
        isTrue,
      );
    });
  });

  group('DeltaChip', () {
    testWidgets('renders gains, losses, flat and missing values', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DeltaChip(percent: 12.4),
            DeltaChip(percent: -8.2, compact: true),
            DeltaChip(percent: 0.01),
            DeltaChip(percent: null),
            DeltaChip(percent: 1234567.89, showArrow: false, label: 'all'),
            DeltaChip(percent: double.nan),
            DeltaChip(percent: double.infinity),
          ],
        ),
      );
      expect(find.text('+12.4%'), findsOneWidget);
      expect(find.text('-8.2%'), findsOneWidget);
      expect(find.text('--'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 2x text scale', (WidgetTester tester) async {
      await _pump(
        tester,
        const DeltaChip(percent: 999999.5, label: 'lifetime'),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('TrendPill', () {
    testWidgets('renders the whole scale', (WidgetTester tester) async {
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TrendPill(label: 'Cold', score01: 0),
            TrendPill(label: 'Neutral', score01: 0.5),
            TrendPill(label: 'Hot', score01: 1),
            TrendPill(label: 'Broken', score01: double.nan),
            TrendPill(label: 'Overflow', score01: 4),
            TrendPill(label: 'Underflow', score01: -3),
          ],
        ),
      );
      expect(find.text('Neutral'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ManaPips', () {
    testWidgets('renders symbols, identities and colourless', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ManaPips(symbols: <String>['U', 'B', 'U']),
            ManaPips(colorIdentity: 'W,U,B,R,G'),
            ManaPips(colorIdentity: ''),
            ManaPips(colorIdentity: null, showColorless: true),
            ManaPips(
              symbols: <String>['X', 'C'],
              showColorless: true,
              size: 22,
            ),
            ManaPips(symbols: <String>['W']),
          ],
        ),
      );
      expect(find.byType(ManaPips), findsNWidgets(6));
      expect(tester.takeException(), isNull);
    });
  });

  group('ManaCostRow', () {
    testWidgets('parses real costs, hybrids and unknown symbols', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ManaCostRow(cost: '{2}{U}{U}'),
            ManaCostRow(cost: '{X}{W/U}{S}{T}{C}'),
            ManaCostRow(cost: '{Q}{half}{10}'),
            ManaCostRow(cost: '3 G G'),
            ManaCostRow(cost: ''),
            ManaCostRow(cost: null),
            ManaCostRow(cost: '{20}', size: 24),
          ],
        ),
      );
      expect(find.text('2'), findsOneWidget);
      expect(find.text('X'), findsOneWidget);
      expect(find.text('Q'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('splits tokens', () {
      expect(ManaCostRow.parse('{2}{U}{U}'), <String>['2', 'U', 'U']);
      expect(ManaCostRow.parse('  '), isEmpty);
      expect(ManaCostRow.parse(null), isEmpty);
      expect(ManaCostRow.parse('WU'), <String>['WU']);
    });
  });

  group('RarityBadge', () {
    testWidgets('renders every rarity in both forms', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final rarity in CardRarity.values)
              RarityBadge(rarity: rarity, compact: true),
            for (final rarity in CardRarity.values) RarityBadge(rarity: rarity),
          ],
        ),
      );
      expect(find.text('Mythic'), findsOneWidget);
      expect(find.text('M'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CardThumbnail', () {
    testWidgets('falls back to the card back without a url', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            CardThumbnail(imageUrl: null, width: 120),
            CardThumbnail(imageUrl: '   ', width: 90),
            CardThumbnail(width: 60, height: 84, quantity: 4),
            CardThumbnail(
              width: 100,
              rarity: CardRarity.mythic,
              quantity: 1234567,
            ),
          ],
        ),
      );
      expect(find.byType(CardBackPlaceholder), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('mounts the cached network image for a real url', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const CardThumbnail(
          imageUrl: 'https://cards.example.test/sol-ring.png',
          width: 100,
        ),
      );
      expect(find.byType(CachedNetworkImage), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });

    testWidgets('honours the 488:680 aspect ratio', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Row(children: <Widget>[CardThumbnail(width: 122)]),
      );
      final size = tester.getSize(find.byType(CardThumbnail));
      expect(size.width, 122);
      expect(size.height, closeTo(122 * 680 / 488, 0.01));
    });

    testWidgets("honours a game's own ratio when it is given one", (
      WidgetTester tester,
    ) async {
      // Yu-Gi-Oh!'s cards are physically 59x86mm where every other game prints
      // 63x88mm, and its art is filed at 813x1185. Drawn in Magic's box with
      // BoxFit.cover that crops the name bar off the top and bottom, so the
      // call sites that know their game hand it theirs.
      await _pump(
        tester,
        const Row(
          children: <Widget>[
            CardThumbnail(width: 118, aspectRatio: 59 / 86),
          ],
        ),
      );
      final size = tester.getSize(find.byType(CardThumbnail));
      expect(size.width, 118);
      expect(size.height, closeTo(118 * 86 / 59, 0.01));
    });

    testWidgets('an explicit height still wins over the ratio', (
      WidgetTester tester,
    ) async {
      // The ratio decides the box only where the box is the widget's to decide:
      // a caller that has already measured its own box keeps what it measured.
      await _pump(
        tester,
        const CardThumbnail(width: 100, height: 140, aspectRatio: 59 / 86),
      );
      final size = tester.getSize(find.byType(CardThumbnail));
      expect(size.height, 140);
    });

    testWidgets('supports hero tags, radius and labels', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const CardThumbnail(
          width: 80,
          heroTag: 'card-hero-1',
          semanticLabel: 'Sol Ring',
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      );
      expect(find.byType(Hero), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 2x text scale with a huge quantity', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const CardThumbnail(width: 70, quantity: 999999),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('CardBackPlaceholder', () {
    testWidgets('fills any box', (WidgetTester tester) async {
      await _pump(
        tester,
        const SizedBox(
          width: 200,
          height: 90,
          child: CardBackPlaceholder(label: 'No art'),
        ),
      );
      expect(
        tester.getSize(find.byType(CardBackPlaceholder)),
        const Size(340, 90),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('TrendGauge', () {
    testWidgets('animates through the score bands', (
      WidgetTester tester,
    ) async {
      for (final score in <double>[0, 35, 50, 65, 100]) {
        await _pump(
          tester,
          TrendGauge(score: score, label: 'Momentum', confidence: 0.7),
        );
        await tester.pump(const Duration(milliseconds: 950));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('clamps out-of-range and non-finite scores', (
      WidgetTester tester,
    ) async {
      await _pump(tester, const TrendGauge(score: -40));
      await tester.pump(const Duration(milliseconds: 950));
      await _pump(
        tester,
        const TrendGauge(score: 480, confidence: double.nan, label: 'Hot'),
      );
      await tester.pump(const Duration(milliseconds: 950));
      await _pump(tester, const TrendGauge(score: double.nan));
      await tester.pump(const Duration(milliseconds: 950));
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 2x text scale', (WidgetTester tester) async {
      await _pump(
        tester,
        const TrendGauge(
          score: 72,
          size: 200,
          label: 'A very long momentum caption indeed',
        ),
        textScale: 2,
      );
      await tester.pump(const Duration(milliseconds: 950));
      expect(tester.takeException(), isNull);
    });
  });

  group('ScoreBar', () {
    testWidgets('renders the whole range', (WidgetTester tester) async {
      await _pump(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ScoreBar(score: 0),
            ScoreBar(score: 42),
            ScoreBar(score: 100, width: 120),
            ScoreBar(score: 900),
            ScoreBar(score: -20),
            ScoreBar(score: double.nan),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SectionHeader', () {
    testWidgets('renders title, subtitle and trailing', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        SectionHeader(
          title: 'Top movers',
          subtitle: 'Last 7 days',
          trailing: TextButton(onPressed: () {}, child: const Text('See all')),
        ),
      );
      expect(find.text('Top movers'), findsOneWidget);
      expect(find.text('See all'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles long copy at 2x text scale', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const SectionHeader(
          title: 'A really quite long section heading that should wrap',
          subtitle: 'And an equally long subtitle that should also wrap away',
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('EmptyState', () {
    testWidgets('renders with and without an action', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        Column(
          children: <Widget>[
            const EmptyState(
              icon: Icons.inbox_rounded,
              title: 'No cards yet',
              message: 'Add your first card to start tracking value.',
            ),
            EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Nothing found',
              compact: true,
              action: FilledButton(onPressed: () {}, child: const Text('Scan')),
            ),
          ],
        ),
      );
      expect(find.text('No cards yet'), findsOneWidget);
      expect(find.text('Scan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('StatTile', () {
    testWidgets('renders label, value, delta and icon', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        Column(
          children: <Widget>[
            const StatTile(
              label: 'Vault value',
              value: '\$12,480.55',
              delta: 4.2,
              icon: Icons.account_balance_wallet_rounded,
              caption: 'vs last week',
            ),
            StatTile(
              label: 'Cards',
              value: '999,999,999',
              delta: -0.02,
              onTap: () {},
              semanticLabel: 'Card count',
            ),
          ],
        ),
      );
      expect(find.text('Vault value'), findsOneWidget);
      expect(find.text('999,999,999'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 2x text scale', (WidgetTester tester) async {
      await _pump(
        tester,
        const StatTile(
          label: 'A very long statistic label here',
          value: '\$1,234,567.89',
          delta: 123.4,
          icon: Icons.trending_up_rounded,
          caption: 'a long caption',
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('LoadingShimmer', () {
    testWidgets('animates without settling', (WidgetTester tester) async {
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            LoadingShimmer(height: 20),
            LoadingShimmer(
              width: 90,
              height: 20,
              borderRadius: BorderRadius.all(Radius.circular(999)),
            ),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(LoadingShimmer), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('AsyncValueView', () {
    testWidgets('renders the loading shimmer', (WidgetTester tester) async {
      await _pump(
        tester,
        AsyncValueView<int>(
          value: const AsyncLoading<int>(),
          builder: (int data) => Text('$data'),
        ),
      );
      expect(find.byType(LoadingShimmer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders data and the empty state', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        AsyncValueView<List<int>>(
          value: const AsyncData<List<int>>(<int>[1, 2, 3]),
          isEmpty: (List<int> data) => data.isEmpty,
          emptyMessage: 'Nothing here',
          builder: (List<int> data) => Text('rows: ${data.length}'),
        ),
      );
      expect(find.text('rows: 3'), findsOneWidget);

      await _pump(
        tester,
        AsyncValueView<List<int>>(
          value: const AsyncData<List<int>>(<int>[]),
          isEmpty: (List<int> data) => data.isEmpty,
          emptyMessage: 'Nothing here',
          builder: (List<int> data) => Text('rows: ${data.length}'),
        ),
      );
      expect(find.text('Nothing here'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders an empty payload as nothing without a message', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        AsyncValueView<List<int>>(
          value: const AsyncData<List<int>>(<int>[]),
          isEmpty: (List<int> data) => data.isEmpty,
          builder: (List<int> data) => Text('rows: ${data.length}'),
        ),
      );
      expect(find.text('rows: 0'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the error card and retries', (
      WidgetTester tester,
    ) async {
      var retried = 0;
      await _pump(
        tester,
        AsyncValueView<int>(
          value: AsyncError<int>(StateError('network down'), StackTrace.empty),
          onRetry: () => retried++,
          builder: (int data) => Text('$data'),
        ),
      );
      expect(find.textContaining('network down'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(retried, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('accepts a custom loading widget', (WidgetTester tester) async {
      await _pump(
        tester,
        AsyncValueView<int>(
          value: const AsyncLoading<int>(),
          loading: const Text('Spinning up'),
          builder: (int data) => Text('$data'),
        ),
      );
      expect(find.text('Spinning up'), findsOneWidget);
    });
  });

  group('PillToggle', () {
    testWidgets('animates its indicator and reports taps', (
      WidgetTester tester,
    ) async {
      var selected = 0;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => PillToggle(
              options: const <String>['All', 'Rare', 'Mythic'],
              selected: selected,
              onChanged: (int i) => setState(() => selected = i),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('Mythic'), findsOneWidget);

      await tester.tap(find.text('Mythic'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(selected, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles empty options and 2x text scale', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const PillToggle(options: <String>[], selected: 0, onChanged: _noop),
      );
      await _pump(
        tester,
        PillToggle(
          options: const <String>['Everything', 'Rares', 'Mythics'],
          selected: 9,
          onChanged: (int _) {},
        ),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

void _noop(int _) {}
