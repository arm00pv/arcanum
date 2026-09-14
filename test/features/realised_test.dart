// What the realised screen draws, without a database or a network.
//
//   flutter test test/features/realised_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/portfolio/lots.dart';
import 'package:arcanum/domain/portfolio/realised.dart';
import 'package:arcanum/features/collection/realised_screen.dart';
import 'package:arcanum/providers.dart';

CardSale sale({
  double unitPrice = 10,
  double fees = 0,
  int quantity = 1,
  DateTime? soldOn,
  List<LotMatch> matches = const <LotMatch>[],
  String note = '',
}) => CardSale(
  id: 1,
  game: CardGame.mtg,
  cardId: 'lea-161',
  quantity: quantity,
  unitPrice: unitPrice,
  fees: fees,
  soldOn: soldOn ?? DateTime(2025, 3, 9),
  note: note,
  matches: matches,
);

SaleRow row(CardSale s, {String name = 'Lightning Bolt'}) => SaleRow(
  sale: s,
  name: name,
  setCode: 'lea',
  setName: 'Limited Edition Alpha',
);

Future<void> pumpRealised(WidgetTester tester, List<SaleRow> rows) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final AppSettings settings = await AppSettings.load(
    secrets: MemorySecretStore(),
  );
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        realisedProvider.overrideWith(
          (ref, CardGame game) async => Realised.of(rows),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: const RealisedScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('shows the year, what arrived and what it made', (
    WidgetTester tester,
  ) async {
    await pumpRealised(tester, <SaleRow>[
      row(
        sale(
          quantity: 2,
          unitPrice: 10,
          fees: 2,
          matches: const <LotMatch>[
            LotMatch(lotId: 1, quantity: 2, unitCost: 4),
          ],
        ),
      ),
    ]);

    // 2 copies at ten, less two in fees, against a cost of eight: ten.
    expect(find.text('REALISED IN 2025'), findsOneWidget);
    // Once as the year's total, once on the sale row.
    expect(find.text('+\$10.00'), findsNWidgets(2));
    expect(find.text('\$18.00'), findsOneWidget);
    expect(find.text('\$8.00'), findsOneWidget);
    expect(find.text('Lightning Bolt'), findsOneWidget);
    expect(find.textContaining('2 × \$10.00'), findsOneWidget);
    // A sale with a known cost says nothing about missing cost basis.
    expect(find.textContaining('no cost basis'), findsNothing);
  });

  testWidgets('says so when a sale has no cost basis', (
    WidgetTester tester,
  ) async {
    await pumpRealised(tester, <SaleRow>[row(sale(unitPrice: 20))]);

    // The gain is unknown, not zero: a zero reads like a loss, and no gain
    // can be worked out from a stack whose purchase price was never recorded.
    expect(find.text('cost unknown'), findsOneWidget);
    expect(find.text('unknown'), findsOneWidget);
    expect(find.text('not recorded'), findsOneWidget);
    expect(find.textContaining('One sale has no cost basis'), findsOneWidget);
    // The money that arrived is still on the sheet.
    expect(find.text('+\$0.00'), findsNothing);
    expect(find.text('\$20.00'), findsOneWidget);
  });

  testWidgets('says nothing has been sold when nothing has', (
    WidgetTester tester,
  ) async {
    await pumpRealised(tester, const <SaleRow>[]);

    expect(find.text('Nothing sold yet'), findsOneWidget);
    expect(
      find.textContaining('record the sale from the card'),
      findsOneWidget,
    );
  });

  testWidgets('groups by year and offers the older ones', (
    WidgetTester tester,
  ) async {
    await pumpRealised(tester, <SaleRow>[
      row(
        sale(
          soldOn: DateTime(2024, 5, 1),
          unitPrice: 3,
          matches: const <LotMatch>[
            LotMatch(lotId: 1, quantity: 1, unitCost: 1),
          ],
        ),
      ),
      row(
        sale(
          soldOn: DateTime(2025, 5, 1),
          unitPrice: 30,
          matches: const <LotMatch>[
            LotMatch(lotId: 2, quantity: 1, unitCost: 10),
          ],
        ),
      ),
    ]);

    // The newest year is on screen and both years are offered.
    expect(find.text('REALISED IN 2025'), findsOneWidget);
    expect(find.text('2024'), findsOneWidget);
    // Once in the header line, once as the year's total.
    expect(find.text('+\$20.00'), findsNWidgets(2));

    await tester.tap(find.text('2024'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('REALISED IN 2024'), findsOneWidget);
    expect(find.text('+\$2.00'), findsNWidgets(2));
  });
}
