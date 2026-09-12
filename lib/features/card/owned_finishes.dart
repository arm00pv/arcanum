import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';

/// The finishes a game prints that the user holds no stack of yet.
///
/// One printing can be owned in more than one finish at once. A foil copy and a
/// non-foil copy of the same card are different physical objects, quoted at
/// different prices, and the database keeps them as separate entries keyed by
/// finish - so once a card is in the collection there is still something worth
/// offering that a plain "add" cannot express: the *other* finishes of that same
/// printing.
///
/// Order follows the game's own [CardGame.finishes], which means a card owned
/// only in foil still offers non-foil first. That is deliberate: the first entry
/// is the finish every other layer treats as the default, and a collector
/// filling in a binder slot starts from the ordinary printing.
///
/// A finish already owned is never offered again, however many stacks of it the
/// user has: adding another is what the quantity stepper is for.
List<CardFinish> missingFinishes(
  Iterable<CollectionEntry> entries,
  CardGame game,
) {
  final owned = <CardFinish>{for (final e in entries) e.finish};
  return <CardFinish>[
    for (final f in game.finishes)
      if (!owned.contains(f)) f,
  ];
}
