import 'package:arcanum/core/utils/codes.dart';

/// A printing named by its collector number, the way a collector says it.
///
/// "BT26-001", "BT-26-001", "ST23-01", "LOB-EN001", "BLB 123a" and a bare "001"
/// are number queries. "Charizard", "Bloomburrow" and "energy removal" are not,
/// and the difference matters: a number is an address, and a search that treats
/// a word as one would answer with noise.
///
/// The parse is narrow on purpose. In front of the number there may be a set
/// code, and whether that is what it is can only be answered by the catalogue -
/// so the candidates are handed over as folded strings for the caller to try,
/// rather than believed here. That is also what keeps a query like "Mewtwo 2"
/// a name search: nothing in the game is called "mewtwo", so it is not a set,
/// and a two-word query is not a bare number either.
class CollectorQuery {
  const CollectorQuery({
    required this.codeCandidates,
    required this.number,
    required this.standalone,
  });

  /// The folded set codes the query might have named, best guess first.
  ///
  /// "BT-26-001" offers one: "bt26". "LOB-EN001" offers two, because the letters
  /// between the set and the number are a printing region - "loben" first, then
  /// "lob" - and only the catalogue knows which of them, if either, is a set.
  final List<String> codeCandidates;

  /// The number as typed: "001", "123a", "4".
  final String number;

  /// True when the query was nothing but the number, so it names no set and
  /// stands on its own. A bare number is only unique inside a set, which is
  /// something the caller has to say out loud rather than hide.
  final bool standalone;

  /// Parses [raw], or returns null when it is not a number query at all.
  ///
  /// Any trailing letters are kept with the number, because a card numbered
  /// "123a" is not card "123". A leading zero is kept too: padding is dropped
  /// later, where the stored number is known.
  static CollectorQuery? parse(String raw) {
    final List<String> tokens = raw
        .trim()
        .split(RegExp(r'[\s\-_/.]+'))
        .where((String t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;

    final String last = tokens.removeLast();
    // Letters, then the number, then anything trailing: "EN001" is region 001,
    // "123a" is 123 with a suffix, "001" is just the number.
    final Match? match = RegExp(r'^([A-Za-z]*)(\d+[A-Za-z]*)$')
        .firstMatch(last);
    if (match == null) return null;

    final String region = match.group(1)!;
    final String number = match.group(2)!;
    final String head = tokens.join();

    return CollectorQuery(
      codeCandidates: <String>[
        if (head.isNotEmpty && region.isNotEmpty) Codes.fold('$head$region'),
        if (head.isNotEmpty) Codes.fold(head),
      ],
      number: number,
      standalone: head.isEmpty && region.isEmpty,
    );
  }
}
