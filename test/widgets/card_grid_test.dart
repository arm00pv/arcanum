import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/widgets/card_grid.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';

/// The shape of a card in a grid, which a fixed tile ratio quietly gets wrong.
///
/// The bug this pins was found by measurement, not by looking: a delegate given
/// a fixed childAspectRatio decides a tile's height from its width, and the art
/// inside the tile was whatever the caption left over. At the 190-wide tile this
/// app uses, that put Magic's art in a 190x322.4 box - 0.589 against a card's
/// 0.718 - so BoxFit.cover cropped about 9% off each side of every game's art.
/// It was spotted through Yu-Gi-Oh!, which was cropped LESS there than Magic
/// was: a game-shaped-looking problem that was really a box-shaped one.
///
/// Two things are asserted, and the second is the one that keeps this honest.
/// The art's rendered shape is the card's, at several widths and text sizes; and
/// the caption still fits the height the grid reserved for it, because a caption
/// taller than its reservation pushes the art back into a crop - the same bug
/// wearing a different hat.
void main() {
  const EdgeInsets padding = EdgeInsets.fromLTRB(14, 10, 14, 120);

  /// The two lines the collection grid puts under a card, at the app's styles.
  Widget twoLineCaption() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Text(
        'Krenko, Mob Boss',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, height: 1.45),
      ),
      const Text('\u00a312.40', style: TextStyle(fontSize: 11, height: 1.45)),
    ],
  );

  /// The three the set grid puts under one: number, price, then name and rarity.
  Widget threeLineCaption() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Text('#42', style: TextStyle(fontSize: 11, height: 1.45)),
      const SizedBox(height: 2),
      const Text(
        'Krenko, Mob Boss',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, height: 1.45),
      ),
    ],
  );

  group('a tile is a card plus its caption', () {
    test('at every width, the art gets the card\'s own shape', () {
      for (final double ratio in <double>[488 / 680, 59 / 86, 600 / 825]) {
        for (final double width in <double>[90, 140, 187, 320, 720, 1180]) {
          final CardTileMetrics m = CardTileMetrics(
            availableWidth: width,
            cardAspectRatio: ratio,
            captionHeight: 56,
          );
          expect(
            m.tileHeight - m.captionHeight,
            closeTo(m.tileWidth / ratio, 0.0001),
            reason: 'width $width, ratio $ratio',
          );
        }
      }
    });

    test('the count is the rule the old delegate had', () {
      expect(
        CardTileMetrics(
          availableWidth: 384,
          cardAspectRatio: 488 / 680,
          captionHeight: 56,
        ).columns,
        2,
        reason: 'a 412-wide phone, less the grid padding',
      );
      expect(
        CardTileMetrics(
          availableWidth: 1180,
          cardAspectRatio: 488 / 680,
          captionHeight: 56,
        ).columns,
        6,
      );
    });

    test('a degenerate width does not divide by zero', () {
      final CardTileMetrics m = CardTileMetrics(
        availableWidth: 0,
        cardAspectRatio: 488 / 680,
        captionHeight: 56,
      );
      expect(m.columns, 1);
      expect(m.tileWidth, 0);
      expect(m.tileHeight, 56);
    });
  });

  group('the grid it builds lays the art out at the card shape', () {
    Future<void> render(
      WidgetTester tester, {
      required double ratio,
      required double captionBase,
      required double textScale,
      required Widget Function() caption,
    }) async {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                SliverLayoutBuilder(
                  builder: (BuildContext context, constraints) {
                    final CardTileMetrics metrics = CardTileMetrics(
                      availableWidth:
                          constraints.crossAxisExtent - padding.horizontal,
                      cardAspectRatio: ratio,
                      captionHeight: cardTileCaptionHeight(
                        context,
                        captionBase,
                      ),
                    );
                    return SliverPadding(
                      padding: padding,
                      sliver: SliverGrid.builder(
                        gridDelegate: metrics.delegate,
                        itemCount: 6,
                        itemBuilder: (BuildContext context, int i) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            LayoutBuilder(
                              builder:
                                  (BuildContext context, BoxConstraints box) =>
                                      CardThumbnail(
                                        width: box.maxWidth,
                                        aspectRatio: ratio,
                                      ),
                            ),
                            const SizedBox(height: 6),
                            // Exactly as the screens do it: the caption takes
                            // the reserved height, so a reservation that is too
                            // small clips the caption rather than cropping the
                            // card - and still fails this test loudly.
                            Expanded(child: caption()),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    void expectArtShape(WidgetTester tester, double ratio) {
      final Iterable<Element> arts = find.byType(CardThumbnail).evaluate();
      expect(arts, isNotEmpty);
      for (final Element art in arts) {
        final Size size = tester.getSize(find.byWidget(art.widget));
        final double w = size.width;
        final double h = size.height;
        expect(
          w / h,
          closeTo(ratio, 0.01),
          reason: 'rendered $w by $h',
        );
      }
    }

    for (final double scale in <double>[1, 2]) {
      testWidgets('Magic, two-line caption, text size $scale', (
        WidgetTester tester,
      ) async {
        await render(
          tester,
          ratio: 488 / 680,
          captionBase: 42,
          textScale: scale,
          caption: twoLineCaption,
        );
        expect(tester.takeException(), isNull, reason: 'the caption must fit');
        expectArtShape(tester, 488 / 680);
      });

      testWidgets('Magic, three-line caption, text size $scale', (
        WidgetTester tester,
      ) async {
        // The set grid, whose reservation is the larger one.
        await render(
          tester,
          ratio: 488 / 680,
          captionBase: 56,
          textScale: scale,
          caption: threeLineCaption,
        );
        expect(tester.takeException(), isNull, reason: 'the caption must fit');
        expectArtShape(tester, 488 / 680);
      });
    }

    testWidgets('Yu-Gi-Oh!, the game that revealed the crop', (
      WidgetTester tester,
    ) async {
      await render(
        tester,
        ratio: 59 / 86,
        captionBase: 56,
        textScale: 1,
        caption: threeLineCaption,
      );
      expect(tester.takeException(), isNull);
      expectArtShape(tester, 59 / 86);
    });
  });
}
