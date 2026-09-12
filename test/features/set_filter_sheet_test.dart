import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/sets/printing_groups.dart';
import 'package:arcanum/features/sets/set_filter_sheet.dart';
import 'package:arcanum/features/sets/set_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TcgCard printing({
  required String id,
  String name = 'Blue-Eyes White Dragon',
  String number = '001',
  String rarity = 'Ultra Rare',
  double? price,
}) =>
    TcgCard(
      game: CardGame.yugioh,
      id: id,
      setCode: 'lob',
      setName: 'Legend of Blue Eyes White Dragon',
      name: name,
      collectorNumber: number,
      rarity: rarity,
      prices: price == null
          ? TcgPrices.empty
          : TcgPrices(byFinish: <String, double?>{CardFinish.nonfoil.code: price}),
    );

List<PrintingSlot> fixture() => groupIntoSlots(<TcgCard>[
      printing(id: 'a', price: 0.14),
      printing(id: 'b', price: 62.15),
      printing(id: 'c', price: 681.5),
      printing(
        id: 'd',
        name: 'Skull Servant',
        number: '002',
        rarity: 'Common',
        price: 0.2,
      ),
      printing(id: 'e', name: 'Dark Magician', number: '003', rarity: 'Super Rare'),
    ]);

void main() {
  late SetFilter? returned;
  late bool closed;

  Future<void> open(WidgetTester tester, {SetFilter? current}) async {
    returned = null;
    closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                onPressed: () async {
                  returned = await showSetFilterSheet(
                    context,
                    current: current ?? const SetFilter(),
                    slots: fixture(),
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('offers every price band, counted against the set', (
    WidgetTester tester,
  ) async {
    await open(tester);

    expect(find.text('Filter cards'), findsOneWidget);
    expect(find.text('Any price'), findsOneWidget);
    for (final band in PriceBand.values) {
      expect(find.text(band.label), findsOneWidget);
    }
    // The set has five printings across three slots, and the sheet opens with
    // nothing filtered.
    expect(find.text('5 of 3'), findsNothing);
    expect(find.text('Show 3 cards'), findsOneWidget);
  });

  testWidgets('hands back the band that was picked', (
    WidgetTester tester,
  ) async {
    await open(tester);

    // Blue-Eyes (0.14) and Skull Servant (0.20) are under a dollar; Dark
    // Magician has no price at all and so is not claimed by the band.
    await tester.tap(find.text(r'Under $1'));
    await tester.pumpAndSettle();
    expect(find.text('Show 2 cards'), findsOneWidget);

    // $20 to $100 keeps only the version of Blue-Eyes priced inside it.
    await tester.tap(find.text(r'$20 - $100'));
    await tester.pumpAndSettle();
    expect(find.text('Show 1 card'), findsOneWidget);

    await tester.tap(find.text('Show 1 card'));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(returned?.price, PriceBand.high.window);
    expect(returned?.apply(fixture()).map((slot) => slot.name), <String>[
      'Blue-Eyes White Dragon',
    ]);
  });

  testWidgets('keeps unpriced cards out of a numeric band', (
    WidgetTester tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('No price'));
    await tester.pumpAndSettle();
    expect(find.text('Show 1 card'), findsOneWidget);

    await tester.tap(find.text('Show 1 card'));
    await tester.pumpAndSettle();
    expect(returned?.apply(fixture()).map((slot) => slot.name), <String>[
      'Dark Magician',
    ]);
  });

  testWidgets('toggles rarities and orders', (WidgetTester tester) async {
    await open(tester);

    // Every rarity the set uses is offered, and only those.
    expect(find.text('Ultra Rare'), findsOneWidget);
    expect(find.text('Common'), findsOneWidget);
    expect(find.text('Super Rare'), findsOneWidget);
    expect(find.text('Mythic'), findsNothing);

    await tester.tap(find.text('Common'));
    await tester.pumpAndSettle();
    expect(find.text('Show 1 card'), findsOneWidget);

    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 1 card'));
    await tester.pumpAndSettle();

    expect(returned?.rarities, <String>{'Common'});
    expect(returned?.sort, SetSort.name);
  });

  testWidgets('opens showing what is already on, and resets it', (
    WidgetTester tester,
  ) async {
    await open(
      tester,
      current: const SetFilter(
        price: PriceWindow(min: 20, max: 100),
        sort: SetSort.priceHigh,
      ),
    );

    expect(find.text(r'$20.00 - $100.00'), findsOneWidget);
    expect(find.text('Show 1 card'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('Show 3 cards'), findsOneWidget);

    await tester.tap(find.text('Show 3 cards'));
    await tester.pumpAndSettle();
    expect(returned, const SetFilter());
  });

  testWidgets('dismissing the sheet decides nothing', (
    WidgetTester tester,
  ) async {
    await open(tester, current: const SetFilter(sort: SetSort.priceLow));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(returned, isNull);
  });
}
