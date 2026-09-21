import 'package:flutter/foundation.dart';

/// Where card art is asked for, for the platform doing the asking.
///
/// Art is not like the catalogue's JSON. The app reads a card's picture by
/// fetching its bytes and decoding them itself, so a browser applies to an
/// image the same rule it applies to an answer: a host that will not name the
/// asking origin is a host whose art never arrives. Three of the hosts these
/// catalogues draw from are in that position - YGOPRODeck's image host and
/// Lorcast's card store send no Access-Control-Allow-Origin at all, and the
/// shop's CDN sends a wildcard that is TCGplayer's to withdraw - so on a web
/// build each of them is replaced by Arcanum's relay, which fetches the same
/// path and adds the header the browser is waiting for. A phone has no origin
/// to be judged against and keeps asking the CDN directly, so image bytes
/// never travel through a host of ours.
///
/// The rule sits here, in one place, rather than in each catalogue's image
/// builder: what this exists to prevent is a catalogue that points at a CDN
/// and is forgotten the next time the platform the app runs on changes.
abstract final class CardArt {
  /// The relay's art route, which answers a host key and the CDN's own path.
  static const String _relay = 'https://marquezhv.com/arcanumweb-api/art';

  /// The hosts a browser may not ask, and the name the relay knows each by.
  ///
  /// Kept in step with the relay's own table by hand.
  ///
  /// **TCGdex is here because naming the origin is not the same as naming it
  /// once.** This table was first written on the belief that TCGdex "does name
  /// the browser", which is true of the header it sends and false of what a
  /// browser makes of it: measured 2026-09-21, its card-art paths answer with
  /// `Access-Control-Allow-Origin: *, *` - the same value twice - and a browser
  /// refuses a multi-valued header outright with `net::ERR_FAILED`. Of 216
  /// Pokemon sets, 186 refused `low.webp`, 208 refused `high.webp` and 165
  /// refused `high.png`, which is to say almost every Pokemon card picture was
  /// missing on the web and the placeholder was drawn instead. The set *logos*
  /// on the same host send a single `*` and were always fine, which is what made
  /// it look like a per-set problem rather than a per-header one.
  ///
  /// A host missing from here is a host the browser is left alone with, which is
  /// the right answer for Scryfall, and was the wrong one for TCGdex.
  static const Map<String, String> _relayed = <String, String>{
    'https://tcgplayer-cdn.tcgplayer.com': 'tcgplayer',
    'https://images.ygoprodeck.com': 'ygoprodeck',
    'https://cards.lorcast.io': 'lorcast',
    'https://assets.tcgdex.net': 'tcgdex',
  };

  /// The address art published at [direct] is fetched from.
  ///
  /// [web] is a browser build reading its own state rather than a choice a
  /// caller makes; it is a parameter so both addresses can be read at once
  /// without running a request through either.
  static String host(String direct, {bool web = kIsWeb}) {
    if (!web) return direct;
    for (final MapEntry<String, String> relayed in _relayed.entries) {
      final String origin = relayed.key;
      // The slash is what keeps a host that merely begins with the name of a
      // relayed one - images.ygoprodeck.com.example.net - from being handed
      // over as though it were the host it imitates.
      if (direct.startsWith('$origin/')) {
        return '$_relay/${relayed.value}${direct.substring(origin.length)}';
      }
    }
    return direct;
  }
}
