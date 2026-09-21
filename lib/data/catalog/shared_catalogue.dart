import 'package:arcanum/domain/models/card_game.dart';

/// The games the shared catalogue holds.
///
/// One set, in one place. Two places is how a game ends up routed to a server
/// that has nothing for it: the app asks Postgres, gets an empty answer, and
/// falls back to the provider - which works, and costs a round trip on every
/// query while reading in a log as though the catalogue were broken.
///
/// Adding a game to the server is adding it here, and the import that fills the
/// tables is a separate job that can run before or after. The router is built
/// for exactly that gap and answers nothing-but-empty from the server by asking
/// the provider, so a game listed here before its import has run behaves as it
/// did before, one wasted request at a time. Taking a game out is deleting the
/// line, and nothing else changes - which is what keeps the rollback for every
/// step of the migration a switch in Settings rather than a release.
///
/// The order of the two halves matters in one direction only: the import must
/// not be the thing that decides. A game the server holds and this set does not
/// name is simply not read from there, which is the safe direction to be wrong
/// in.
const Set<CardGame> sharedCatalogueGames = <CardGame>{
  CardGame.lorcana,
  CardGame.pokemon,
};

/// Those games, named for a person: "Lorcana and Pokemon".
///
/// Built from the set rather than written out, because the sentence on the
/// Settings switch has to move when the set does. It said "Read Lorcana from
/// Arcanum" the moment a second game was added to the server, which is a switch
/// that lies about what it is switching.
///
/// The set is a parameter so the shape of the sentence can be tested - one game
/// with no conjunction, three with commas, none at all - rather than only ever
/// being seen in the one form today's list happens to produce. The order comes
/// from [CardGame.values] rather than from the set, so the sentence reads in the
/// order the app lists games everywhere else.
String sharedCatalogueGamesNamed([
  Set<CardGame> games = sharedCatalogueGames,
]) {
  final List<String> names = CardGame.values
      .where(games.contains)
      .map((CardGame game) => game.shortLabel)
      .toList();
  if (names.isEmpty) return 'no game yet';
  if (names.length == 1) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}
