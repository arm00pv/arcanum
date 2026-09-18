// Tests for the host card art is asked for.
//
//   flutter test test/catalog/card_art_test.dart
//
// Nothing here touches the network - the chooser is a string function - and the
// addresses themselves are what is pinned, because a wrong one is a picture
// that never arrives and a fault that only shows up in a browser build.

import 'package:arcanum/data/catalog/card_art.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the host art is asked for', () {
    // One URL per host the relay stands in front of: the shop's CDN, which is
    // where the five games tcgcsv catalogues and Lorcana both get their art;
    // YGOPRODeck's image host for Yu-Gi-Oh!; and Lorcast's card store for the
    // Lorcana promos that have no TCGplayer product.
    const String shop =
        'https://tcgplayer-cdn.tcgplayer.com/product/673302_400w.jpg';
    const String ygo =
        'https://images.ygoprodeck.com/images/cards/89631139.jpg';
    const String promo =
        'https://cards.lorcast.io/card/digital/normal/crd_a6f3.avif?1755566321';

    test('is the CDN itself on a phone', () {
      // A phone sends no Origin and nothing judges its answers, so its art goes
      // where it always went and not one byte of it passes through a host of
      // ours.
      expect(CardArt.host(shop, web: false), shop);
      expect(CardArt.host(ygo, web: false), ygo);
      expect(CardArt.host(promo, web: false), promo);
    });

    test('and Arcanum on a web build', () {
      // Every one of those hosts leaves a browser without the bytes of its own
      // picture, so a web build gets the relay with the CDN's path kept behind
      // it - the query included, which is how Lorcast versions a promo's art.
      expect(
        CardArt.host(shop, web: true),
        'https://marquezhv.com/arcanumweb-api/art/tcgplayer/product/673302_400w.jpg',
      );
      expect(
        CardArt.host(ygo, web: true),
        'https://marquezhv.com/arcanumweb-api/art/ygoprodeck/images/cards/89631139.jpg',
      );
      expect(
        CardArt.host(promo, web: true),
        'https://marquezhv.com/arcanumweb-api/art/lorcast/card/digital/normal/'
        'crd_a6f3.avif?1755566321',
      );
    });

    test('leaves a host that already answers a browser where it is', () {
      // Scryfall and TCGdex send Access-Control-Allow-Origin themselves, and
      // between them they carry most of the art the app shows: relaying them
      // would spend this host's bandwidth and the user's wait on a header the
      // CDN was giving away.
      const String magic = 'https://cards.scryfall.io/normal/front/0/0/abc.jpg';
      const String pokemon =
          'https://assets.tcgdex.net/en/base/base1/4/high.webp';

      expect(CardArt.host(magic, web: true), magic);
      expect(CardArt.host(pokemon, web: true), pokemon);
      // A host is recognised by its name and the slash that ends it, so a name
      // only beginning with a relayed one is not handed over as though it were
      // that host.
      const String impostor = 'https://images.ygoprodeck.com.example.net/a.jpg';
      expect(CardArt.host(impostor, web: true), impostor);
    });

    test('and the build is what decides, not the caller', () {
      // The address is read from the platform rather than passed in, so the
      // default is what a browser build would take and this test run, which is
      // not a browser, takes the CDN.
      expect(CardArt.host(shop), CardArt.host(shop, web: false));
    });
  });
}
