import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/widgets/mana_pips.dart';

/// A Yu-Gi-Oh! printing, which is the only provider that publishes a shorthand.
TcgCard ygoCard({String? rarityCode, String rarity = 'Ultra Rare'}) => TcgCard(
      game: CardGame.yugioh,
      id: '89631139:lob:001:ultra-rare',
      setCode: 'lob',
      setName: 'Legend of Blue Eyes White Dragon',
      name: 'Blue-Eyes White Dragon',
      collectorNumber: '001',
      rarity: rarity,
      extras: <String, Object?>{'rarityCode': ?rarityCode},
    );

Future<void> pumpBadge(WidgetTester tester, RarityBadge badge) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(body: Center(child: badge)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('TcgCard.rarityCode', () {
    test('unwraps the provider shorthand', () {
      expect(ygoCard(rarityCode: '(UR)').rarityCode, 'UR');
      expect(ygoCard(rarityCode: '(ScR)').rarityCode, 'ScR');
      expect(ygoCard(rarityCode: '(StR)').rarityCode, 'StR');
      expect(ygoCard(rarityCode: '(C)').rarityCode, 'C');
    });

    test('accepts a code that arrives without parentheses', () {
      expect(ygoCard(rarityCode: 'UR').rarityCode, 'UR');
      expect(ygoCard(rarityCode: '  (SR)  ').rarityCode, 'SR');
    });

    test('is null when the provider publishes no shorthand', () {
      // Magic and Pokémon publish tiers, not rarities, so they stay null and
      // the badge falls back to the tier letter.
      expect(ygoCard().rarityCode, isNull);
    });

    test('is null for an empty or non-string code', () {
      expect(ygoCard(rarityCode: '').rarityCode, isNull);
      expect(ygoCard(rarityCode: '   ').rarityCode, isNull);
      expect(ygoCard(rarityCode: '()').rarityCode, isNull);
    });
  });

  group('RarityBadge', () {
    testWidgets('shows the provider shorthand when there is one', (tester) async {
      await pumpBadge(
        tester,
        RarityBadge(
          rarity: CardRarity.mythic,
          compact: true,
          code: ygoCard(rarityCode: '(ScR)').rarityCode,
        ),
      );

      // The point of the whole exercise: two premium tiers can no longer render
      // as the same badge.
      expect(find.text('ScR'), findsOneWidget);
      expect(find.text('M'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('falls back to the tier letter without a shorthand',
        (tester) async {
      await pumpBadge(
        tester,
        const RarityBadge(rarity: CardRarity.mythic, compact: true),
      );

      expect(find.text('M'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('spells the rarity out in the wide form, code or not',
        (tester) async {
      await pumpBadge(
        tester,
        const RarityBadge(rarity: CardRarity.rare, code: 'UR'),
      );

      // The wide form has the room, so a code would be a step backwards.
      expect(find.text('Rare'), findsOneWidget);
      expect(find.text('UR'), findsNothing);
    });

    testWidgets('keeps the tier letter for the other games', (tester) async {
      for (final entry in <CardRarity, String>{
        CardRarity.common: 'C',
        CardRarity.uncommon: 'U',
        CardRarity.rare: 'R',
        CardRarity.special: 'S',
        CardRarity.bonus: 'B',
        CardRarity.unknown: '?',
      }.entries) {
        await pumpBadge(
          tester,
          RarityBadge(rarity: entry.key, compact: true),
        );
        expect(find.text(entry.value), findsOneWidget);
      }
    });
  });
}
