import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/api/scryfall_client.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Translates Scryfall's wire format into Arcanum's game-agnostic domain model.
///
/// Kept separate from both so that neither the API client nor the domain has to
/// know about the other: Scryfall data can change shape without touching the
/// app, and the domain never grows a Scryfall-shaped field.
extension ScryfallCardAdapter on ScryfallCard {
  /// Converts this printing into the shared [TcgCard] model.
  TcgCard toTcgCard() => TcgCard(
    game: CardGame.mtg,
    id: id,
    setCode: setCode,
    setName: setName,
    name: name,
    collectorNumber: collectorNumber,
    rarity: rarity,
    layout: layout,
    typeLine: typeLine,
    oracleText: oracleText,
    manaCost: manaCost,
    artist: artist,
    flavorText: flavorText,
    cmc: cmc,
    colors: colors,
    colorIdentity: colorIdentity,
    digital: digital,
    foil: foil,
    nonfoil: nonfoil,
    promo: promo,
    reprint: reprint,
    reserved: reserved,
    fullArt: fullArt,
    booster: booster,
    releasedAt: releasedAt,
    prices: TcgPrices(
      byFinish: {
        CardFinish.nonfoil.code: prices.usd,
        CardFinish.foil.code: prices.usdFoil,
        CardFinish.etched.code: prices.usdEtched,
      },
      secondary: {
        'eur': prices.eur,
        'eurFoil': prices.eurFoil,
        'eurEtched': prices.eurEtched,
        'tix': prices.tix,
      },
    ),
    imageUris: imageUris,
    faces: [
      for (final f in faces)
        TcgCardFace(
          name: f.name,
          typeLine: f.typeLine,
          text: f.oracleText,
          cost: f.manaCost,
          artist: f.artist,
          imageUris: f.imageUris,
        ),
    ],
    scryfallUri: scryfallUri,
    edhrecRank: edhrecRank,
    oracleId: oracleId,
  );
}

/// Converts a batch of Scryfall printings.
extension ScryfallCardListAdapter on List<ScryfallCard> {
  List<TcgCard> toTcgCards() => [for (final c in this) c.toTcgCard()];
}

/// Translates a Scryfall set into the shared [TcgSet] model.
extension ScryfallSetAdapter on ScryfallSet {
  /// Converts this set into the shared [TcgSet] model.
  TcgSet toTcgSet() => TcgSet(
    game: CardGame.mtg,
    id: id,
    code: code,
    name: name,
    setType: setType,
    releasedAt: releasedAt,
    cardCount: cardCount,
    printedSize: printedSize,
    iconSvgUri: iconSvgUri,
    digital: digital,
    foilOnly: foilOnly,
    nonfoilOnly: nonfoilOnly,
    parentSetCode: parentSetCode,
    blockCode: blockCode,
    block: block,
    collectorNumberStart: collectorNumberStart,
    scryfallUri: scryfallUri,
    searchUri: searchUri,
  );
}

/// Converts a batch of Scryfall sets.
extension ScryfallSetListAdapter on List<ScryfallSet> {
  List<TcgSet> toTcgSets() => [for (final s in this) s.toTcgSet()];
}
