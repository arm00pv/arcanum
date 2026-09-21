// A live probe of the Digimon catalogue, against the real source.
//
//   flutter test tool/catalog/probe_digimon_live.dart
//
// **Not part of the suite**: it needs the network, so `flutter test` on the test
// directory does not pick it up, and it is run by naming it. What it is for is the
// one thing a fake adapter cannot answer - whether Heroicc really answers the routes
// this client asks, whether the parallel ids really stay apart, whether a card really
// names the release it is filed under, and whether the live numbers are the ones the
// catalogue's own comments claim. One set is walked whole (bt-08, 138 cards) plus a
// search and a handful of by-id reads: about 150 requests and 1 MB.

import 'dart:io';

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/digimon_catalog.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the live source answers every question the client asks it', () async {
    // flutter_test replaces the HTTP client with one that answers 400 for every
    // request, so a live probe has to put the real one back.
    HttpOverrides.global = null;
    final DigimonCatalog catalog = DigimonCatalog();

    final List<(int, int)> ticks = <(int, int)>[];
    final List<TcgSet> sets = await catalog.fetchAllSets(
      onProgress: (int done, int total) => ticks.add((done, total)),
    );
    print('sets: ' + sets.length.toString() + ', ticks ' + ticks.length.toString());
    print('  dated: ' + sets.where((TcgSet s) => s.releasedAt != null).length.toString());
    print('  entries: ' + sets.fold<int>(0, (int a, TcgSet s) => a + s.cardCount).toString());
    final Map<String, int> kinds = <String, int>{};
    for (final TcgSet s in sets) {
      kinds[s.setType] = (kinds[s.setType] ?? 0) + 1;
    }
    print('  set types: ' + kinds.toString());
    for (final TcgSet s in sets.take(3)) {
      print('  ' + s.id.padRight(12) + s.code.padRight(10) +
          s.cardCount.toString().padLeft(5) + '  ' +
          (s.releasedAt?.toIso8601String().split('T').first ?? '-').padRight(12) +
          s.setType.padRight(10) + s.name);
    }

    // The folded code a screen holds, not the slug the source addresses: the
    // adapter resolves one to the other from the set list, which is the thing a
    // live check found and a unit test could not.
    final List<TcgCard> cards = await catalog.fetchCardsInSet('bt08');
    print('bt-08: ' + cards.length.toString() + ' cards');
    final TcgCard base = cards.firstWhere((TcgCard c) => c.id == 'BT8-022');
    print('  ' + base.id + ' #' + base.collectorNumber + ' ' + base.name +
        ' [' + (base.typeLine ?? '') + '] ' + base.rarity +
        ' cmc=' + base.cmc.toString() + ' colors=' + base.colors.toString());
    print('  art ' + (base.imageUris['normal'] ?? 'none'));
    print('  oracle ' + (base.oracleId ?? 'none') + '  extras ' +
        base.extras.toString());
    final TcgCard parallel = cards.firstWhere((TcgCard c) => c.id == 'BT5-007_P3');
    print('  parallel ' + parallel.id + ' #' + parallel.collectorNumber +
        ' oracle ' + (parallel.oracleId ?? 'none') + ' set ' + parallel.setCode +
        ' (' + parallel.setName + ')');
    print('  ids unique: ' +
        (cards.map((TcgCard c) => c.id).toSet().length == cards.length).toString());
    print('  distinct cards: ' +
        cards.map((TcgCard c) => c.oracleId).toSet().length.toString());
    print('  set codes: ' +
        cards.map((TcgCard c) => c.setCode).toSet().toString());

    final TcgCard? one = await catalog.fetchCardById('BT5-007_P3');
    print('by id BT5-007_P3: ' + (one == null
        ? 'null'
        : one.setCode + ' ' + one.name + ' oracle ' + (one.oracleId ?? 'none')));

    final List<TcgCard> hits = await catalog.search('agumon');
    print('search agumon: ' + hits.length.toString() + ' hits, first ' +
        (hits.isEmpty ? 'none' : hits.first.name + ' (' + hits.first.id + ')'));
    final List<TcgCard> byNumber =
        await catalog.fetchCardsByNumber(CollectorQuery.parse('BT5-007')!);
    print('number BT5-007: ' + byNumber.length.toString() + ' printings ' +
        byNumber.map((TcgCard c) => c.id).toList().toString());
  }, timeout: const Timeout(Duration(minutes: 10)));
}