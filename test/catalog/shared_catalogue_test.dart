import 'package:arcanum/data/catalog/shared_catalogue.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sentence on the Settings switch, and the list it is built from.
///
/// Worth a test for one reason: this text was wrong the moment the server took
/// on a second game, and nothing failed. The switch went on saying "Read Lorcana
/// from Arcanum" while it had already started deciding what Pokemon did too - a
/// control that misdescribes itself is worse than one that is missing, because
/// the collector trusts it.
void main() {
  group('the shared catalogue names its games', () {
    test('one game needs no conjunction', () {
      expect(
        sharedCatalogueGamesNamed(<CardGame>{CardGame.mtg}),
        'Magic',
      );
    });

    test('two games are joined with "and", in the app\'s order', () {
      // Pokemon sits above Lorcana in CardGame.values, which is where the order
      // comes from. Written as the set reads, this sentence would come out the
      // other way round - and a Set has no order to rely on anyway.
      expect(
        sharedCatalogueGamesNamed(<CardGame>{CardGame.lorcana, CardGame.pokemon}),
        'Pokémon and Lorcana',
      );
    });

    test('three games take commas and a final "and"', () {
      expect(
        sharedCatalogueGamesNamed(
          <CardGame>{CardGame.mtg, CardGame.pokemon, CardGame.lorcana},
        ),
        'Magic, Pokémon and Lorcana',
      );
    });

    test('the order is the app\'s own, not the set\'s', () {
      // A Set has no order to speak of, so a sentence built by iterating one is
      // a sentence that reads differently from run to run. This pins the order
      // to CardGame.values, which is the order every other list in the app uses.
      expect(
        sharedCatalogueGamesNamed(<CardGame>{CardGame.gundam, CardGame.mtg}),
        'Magic and Gundam',
        reason: 'Magic comes before Gundam in CardGame.values',
      );
    });

    test('an empty list says so rather than reading as a broken sentence', () {
      expect(sharedCatalogueGamesNamed(<CardGame>{}), 'no game yet');
    });

    test('the list the app actually uses holds the games with an importer', () {
      // Not a restatement of the constant for its own sake: every game named
      // here is one the app will ask Postgres for, and a game named before its
      // import has run costs a wasted round trip on every query. Adding one is
      // a deliberate act and this is where it is written down. Gundam joined
      // with tool/import_gundam_catalogue.py, which fills its tables from
      // gcgapi, Star Wars: Unlimited with tool/import_swu_catalogue.py, which
      // fills them from the publisher's own card database, and Digimon with
      // tool/import_digimon_catalogue.py, which fills them from Heroicc - the
      // one of the three whose terms are a licence rather than an API.
      expect(
        sharedCatalogueGames,
        <CardGame>{
          CardGame.lorcana,
          CardGame.pokemon,
          CardGame.gundam,
          CardGame.starWarsUnlimited,
          CardGame.digimon,
        },
      );
    });
  });
}
