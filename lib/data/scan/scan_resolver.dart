import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/scan/card_scan.dart';

/// The two questions a scan asks of a catalogue.
///
/// Narrow on purpose. A resolver handed the whole catalogue would eventually
/// use more of it than it should, and the two things a scan needs to know are
/// exactly these: what is at this position, and what printings carry this name.
abstract interface class ScanCatalogue {
  /// The printing at [collectorNumber] in [setCode], or null when there is none.
  Future<TcgCard?> byNumber(
    CardGame game,
    String setCode,
    String collectorNumber,
  );

  /// Printings whose name matches [name], best first.
  Future<List<TcgCard>> byName(
    CardGame game,
    String name, {
    required int limit,
  });
}

/// A [ScanCatalogue] backed by the app's own catalogue.
class RepositoryScanCatalogue implements ScanCatalogue {
  const RepositoryScanCatalogue(this._catalog);

  final CatalogRepository _catalog;

  @override
  Future<TcgCard?> byNumber(
    CardGame game,
    String setCode,
    String collectorNumber,
  ) => _catalog.cardByNumber(game, setCode, collectorNumber);

  @override
  Future<List<TcgCard>> byName(
    CardGame game,
    String name, {
    required int limit,
  }) => _catalog.search(game, name, limit: limit);
}

/// What a scan turned into.
///
/// Three outcomes rather than one, because a scan that picked the wrong
/// printing of a reprinted common is worse than a scan that admits it cannot
/// tell: one writes the wrong card into the collection, the other asks.
class ScanResolution {
  const ScanResolution({
    this.exact,
    this.candidates = const <TcgCard>[],
    this.note,
  });

  /// The one printing the scan named, when a set code and a number both came
  /// off the card. Null when the scan was not that specific.
  final TcgCard? exact;

  /// The printings it might be, when it could not be narrowed to one.
  final List<TcgCard> candidates;

  /// Why it could not be narrowed, in words, for the screen to show.
  final String? note;

  /// True when nothing at all was found.
  bool get isEmpty => exact == null && candidates.isEmpty;

  /// The one printing, whether it was certain or the only possibility.
  TcgCard? get best =>
      exact ?? (candidates.length == 1 ? candidates.first : null);
}

/// Turns what was read off a photograph into printings the catalogue holds.
///
/// The order matters, and it is the whole design. A set code and a collector
/// number name exactly one printing in the entire game, so that is tried first
/// and trusted. A name and a number narrow a reprint to a handful. A name alone
/// is a search, and is offered as candidates rather than as a decision - the
/// scanner's job is to save typing, not to guess which Llanowar Elves is in the
/// collector's hand.
class ScanResolver {
  const ScanResolver({required ScanCatalogue catalogue})
    : _catalogue = catalogue;

  final ScanCatalogue _catalogue;

  /// How many candidates are worth showing before a question becomes a search.
  static const int maxCandidates = 12;

  Future<ScanResolution> resolve(CardGame game, CardScan scan) async {
    final number = scan.collectorNumber;
    final code = scan.setCode;

    // ---------------------------------------------------- set and number
    if (code != null && number != null) {
      final card = await _cardByNumber(game, code, number);
      if (card != null) return ScanResolution(exact: card);
      return ScanResolution(note: 'Nothing in $code is numbered $number.');
    }

    // -------------------------------------------------------- name lookup
    final name = scan.name;
    if (name == null || name.trim().length < 3) {
      return const ScanResolution(
        note: 'No set code, number or name could be read.',
      );
    }

    final byName = await _catalogue.byName(game, name, limit: 40);
    if (byName.isEmpty) {
      return ScanResolution(note: 'No card called "$name" in the catalogue.');
    }

    if (number != null) {
      final matching = <TcgCard>[
        for (final TcgCard card in byName)
          if (_sameNumber(card.collectorNumber, number)) card,
      ];
      if (matching.length == 1) return ScanResolution(exact: matching.first);
      if (matching.isNotEmpty) {
        return ScanResolution(
          candidates: matching,
          note: '$name is at $number in more than one set.',
        );
      }
    }

    // A name on its own is a question, not an answer. Printings whose name is
    // not exactly what was read are dropped first, because a search for
    // 'Goblin' returns a hundred cards and none of them is the one in hand.
    final exactName = <TcgCard>[
      for (final TcgCard card in byName)
        if (card.name.toLowerCase() == name.toLowerCase()) card,
    ];
    final offered = exactName.isEmpty ? byName : exactName;
    return ScanResolution(
      candidates: offered.take(maxCandidates).toList(),
      note: offered.length == 1
          ? null
          : '$name matches ${offered.length} printings',
    );
  }

  /// A printing by set code and number, trying the leading zeros both ways.
  ///
  /// A card prints '007' and a collector says seven; providers store one or the
  /// other depending on the game and the set, and refusing to look for the
  /// other spelling would make the scanner wrong for a reason nobody could see.
  Future<TcgCard?> _cardByNumber(
    CardGame game,
    String setCode,
    String number,
  ) async {
    final direct = await _catalogue.byNumber(game, setCode, number);
    if (direct != null) return direct;

    final stripped = number.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
    if (stripped != number) {
      final without = await _catalogue.byNumber(game, setCode, stripped);
      if (without != null) return without;
    }
    final pad = number.padLeft(3, '0');
    if (pad != number && RegExp(r'^[0-9]{1,3}$').hasMatch(number)) {
      final padded = await _catalogue.byNumber(game, setCode, pad);
      if (padded != null) return padded;
    }
    return null;
  }

  /// True when two collector numbers mean the same position.
  static bool _sameNumber(String a, String b) {
    if (a == b) return true;
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    return na != null && nb != null && na == nb;
  }
}
