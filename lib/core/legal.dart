/// Attribution and policy notices the app is required to display.
///
/// Both publishers license third-party apps to use their card data under
/// revocable, non-commercial terms, and both require specific wording. The
/// notices below are reproduced verbatim because paraphrasing them is not a
/// substitute — Wizards' policy prescribes its text word for word.
///
/// Neither notice may be removed, and neither game may be promoted in the app's
/// name, icon or store listing. "Arcanum" is a neutral product name; a name like
/// "Arcanum — MTG Tracker" would breach both licences.
abstract final class Legal {
  /// Verbatim notice required by the Wizards of the Coast Fan Content Policy.
  ///
  /// Source: https://company.wizards.com/en/legal/fancontentpolicy
  static const wizardsFanContent =
      'Arcanum is unofficial Fan Content permitted under the Fan Content Policy. '
      'Not approved/endorsed by Wizards. Portions of the materials used are '
      'property of Wizards of the Coast. ©Wizards of the Coast LLC.';

  /// Non-affiliation statement for The Pokémon Company International.
  ///
  /// TPCi's Media Usage Guidelines permit card imagery for informational use
  /// only, forbid commercialisation, and require that their branding never
  /// imply endorsement. Source:
  /// https://pokemon.gamespress.com/Media-Usage-Guidelines
  static const pokemonNotice =
      'Arcanum is an unofficial, non-commercial reference tool. It is not '
      'affiliated with, endorsed by, sponsored by or approved by The Pokémon '
      'Company, Nintendo, Creatures Inc. or GAME FREAK inc. Pokémon and Pokémon '
      'character names are trademarks of their respective owners.';

  /// Non-affiliation statement for Disney Lorcana.
  ///
  /// Ravensburger publishes Lorcana under licence from Disney, and neither
  /// offers a fan-content licence as permissive or as explicit as Wizards' and
  /// TPCi's, so this claims the least that can honestly be claimed: the app is
  /// unofficial, it is not commercial, and it implies no endorsement by anyone.
  static const lorcanaNotice =
      'Arcanum is an unofficial, non-commercial reference tool. It is not '
      'affiliated with, endorsed by, sponsored by or approved by Ravensburger '
      'or The Walt Disney Company. Disney Lorcana and Disney character names '
      'are trademarks of their respective owners.';

  /// What the app does with the user's data. Written to match the app's actual
  /// behaviour, which is the point: it collects nothing.
  static const privacySummary =
      'Arcanum stores your collection only on this device, in a private local '
      'database. There is no account, no sign-in, no analytics and no crash '
      'reporting, and nothing you enter is uploaded anywhere. The app contacts '
      'third-party card and price services to fetch catalogue data and prices; '
      'those requests contain no information about you or your collection. '
      'Uninstalling the app, or using Settings to clear a collection, deletes '
      'the data permanently and Arcanum keeps no copy.';

  /// Credits for every third-party service the app depends on.
  static const dataSources = <({String name, String purpose, String url})>[
    (
      name: 'Scryfall',
      purpose: 'Magic card data, set symbols and card images',
      url: 'https://scryfall.com/docs/api',
    ),
    (
      name: 'MTGJSON',
      purpose: 'Magic price history (TCGplayer market prices)',
      url: 'https://mtgjson.com',
    ),
    (
      name: 'MTGStocks',
      purpose: 'Long-range Magic price history',
      url: 'https://mtgstocks.com',
    ),
    (
      name: 'TCGdex',
      purpose: 'Pokémon card data, set logos and current prices',
      url: 'https://tcgdex.dev',
    ),
    (
      name: 'tcgdex/price-history',
      purpose: 'Archived Pokémon price history to September 2024 (MIT)',
      url: 'https://github.com/tcgdex/price-history',
    ),
    (
      name: 'JustTCG',
      purpose: 'Optional live price history (bring your own free key)',
      url: 'https://justtcg.com',
    ),
    (
      name: 'Lorcast',
      purpose: 'Lorcana card data, card text and current prices',
      url: 'https://lorcast.com',
    ),
    (
      name: 'TCGplayer',
      purpose: 'Lorcana card images',
      url: 'https://www.tcgplayer.com',
    ),
  ];

  /// What the app deliberately does not do, stated plainly.
  static const nonCommercial =
      'Arcanum is free and has no ads, no subscriptions and no in-app '
      'purchases. Every publisher whose game it covers permits unofficial '
      'reference apps only while they are non-commercial, so there is nothing '
      'to buy and nothing to unlock.';
}
