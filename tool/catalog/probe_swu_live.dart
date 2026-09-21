// A live probe of the Star Wars: Unlimited catalogue, against the real source.
//
//   flutter test tool/catalog/probe_swu_live.dart
//
// **Not part of the suite**: it needs the network, so `flutter test` on the test
// directory does not pick it up, and it is run by naming it. What it is for is the
// one thing a fake adapter cannot answer - whether the source really accepts the
// bracketed filter keys this client builds, whether the card list really pages the
// way it is read, and whether the live numbers are the ones the catalogue's own
// comments claim. It reads about 15 MB and makes about 35 requests.
//
// It is written as a test rather than as a script because the catalogue reaches
// Flutter through CardArt, so it cannot be run by `dart run`.

import 'dart:io';

import 'package:arcanum/data/catalog/swu_catalog.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the live source answers every question the client asks it', () async {
    // flutter_test replaces the HTTP client with one that answers 400 for every
    // request, so a live probe has to put the real one back.
    HttpOverrides.global = null;
    final SwuCatalog catalog = SwuCatalog();

    final List<(int, int)> ticks = <(int, int)>[];
    final List<TcgSet> sets = await catalog.fetchAllSets(
      onProgress: (int done, int total) => ticks.add((done, total)),
    );
    print('sets: ' + sets.length.toString() +', ticks ' + ticks.length.toString());
    print('  total base printings: ' +
        sets.fold<int>(0, (int a, TcgSet s) => a + s.cardCount).toString());
    for (final TcgSet s in sets.take(4)) {
      print('  ' + s.id.padRight(6) + s.code.padRight(7) +
          s.cardCount.toString().padLeft(5) + '  ' + s.setType.padRight(10) + s.name);
    }
    print('  last: ' + sets.last.id + ' ' + sets.last.name);

    final List<TcgCard> sor = await catalog.fetchCardsInSet('sor');
    print('SOR: ' + sor.length.toString() + ' cards');
    final TcgCard base = sor.firstWhere((TcgCard c) => c.id == '2579145458');
    print('  ' + base.id + ' #' + base.collectorNumber + ' ' + base.name +
        ' [' + (base.typeLine ?? '') + '] ' + base.rarity + ' cmc=' + base.cmc.toString());
    print('  art ' + (base.imageUris['normal'] ?? 'none'));
    final TcgCard variant =
        sor.firstWhere((TcgCard c) => c.extras['variantOf'] == '2579145458');
    print('  variant ' + variant.id + ' #' + variant.collectorNumber +
        ' ' + variant.extras['variantTypes'].toString() +
        ' art ' + (variant.imageUris['normal'] ?? 'none'));
    print('  ids unique: ' +
        (sor.map((TcgCard c) => c.id).toSet().length == sor.length).toString());
    print('  distinct numbers: ' +
        sor.map((TcgCard c) => c.collectorNumber).toSet().length.toString());
    print('  promos: ' + sor.where((TcgCard c) => c.promo).length.toString());
    print('  foils: ' + sor.where((TcgCard c) => c.foil).length.toString());

    final List<TcgCard> hits = await catalog.search('luke');
    print('search luke: ' + hits.length.toString() + ' hits');
    final Map<String, TcgCard> byId = await catalog.fetchCardsByIds(
      <String>['2579145458', '6202608327'],
    );
    print('by ids: ' +
        byId.values.map((TcgCard c) => c.id + ':#' + c.collectorNumber).join(', '));
  }, timeout: const Timeout(Duration(minutes: 10)));
}