/// Reading a list of cards that somebody pasted in.
///
/// Every deck site, every trade message and every spreadsheet writes a card
/// list in roughly the same handful of ways, and none of them are CSV:
///
///     4 Lightning Bolt
///     4x Lightning Bolt
///     Lightning Bolt x4
///     4 Lightning Bolt (LEA) 161
///     1 Sol Ring (LTC) 284 *F*
///     Sideboard
///
/// This turns those into something the app can look up. It is deliberately
/// forgiving about spacing and punctuation and deliberately strict about one
/// thing: a line it cannot read becomes a reported failure rather than a
/// silent guess, because importing the wrong printing of a card is worse than
/// importing none of it.
library;

/// One card a pasted list asked for.
class ListEntry {
  const ListEntry({
    required this.quantity,
    required this.name,
    required this.line,
    this.setCode,
    this.collectorNumber,
    this.foil = false,
  });

  /// How many copies were asked for. Never zero.
  final int quantity;

  /// The card's name, with any printing details stripped off.
  final String name;

  /// The set code, when the line gave one.
  final String? setCode;

  /// The collector number, when the line gave one.
  final String? collectorNumber;

  /// True when the line marked the card as foil.
  final bool foil;

  /// Which line of the pasted text this came from, counting from one.
  final int line;

  /// True when the line identified the exact printing.
  bool get isExact => setCode != null && collectorNumber != null;
}

/// A line that could not be read, kept so it can be shown back.
class ListRejection {
  const ListRejection({required this.line, required this.text});

  final int line;
  final String text;
}

/// What a pasted list turned into.
class ParsedList {
  const ParsedList({
    required this.entries,
    required this.rejected,
    required this.sections,
  });

  final List<ListEntry> entries;

  /// Lines that mentioned neither a name nor a quantity.
  final List<ListRejection> rejected;

  /// Section headings that were passed over, e.g. `Sideboard`.
  final List<String> sections;

  int get cards => entries.fold(0, (int a, ListEntry e) => a + e.quantity);

  bool get isEmpty => entries.isEmpty;
}

/// The words deck sites use to divide a list up.
///
/// A section is skipped, not parsed: a card named "Sideboard" does not exist,
/// and the alternative - importing a card by that name - would be worse than
/// ignoring the line.
const _sections = <String>{
  'deck',
  'main',
  'mainboard',
  'sideboard',
  'commander',
  'companion',
  'maybeboard',
  'maybe',
  'tokens',
  'lands',
  'creatures',
  'instants',
  'sorceries',
  'enchantments',
  'artifacts',
  'planeswalkers',
  'about',
  'name',
  'exported from',
};

/// `4 Name`, `4x Name` or `4 x Name`.
final _leading = RegExp(r'^(\d{1,4})\s*[xX]?\s+(.+)$');

/// `Name x4`.
final _trailing = RegExp(r'^(.+?)\s+[xX]\s*(\d{1,4})$');

/// `(LEA) 161` - the printing, as every deck site writes it.
final _parenPrinting = RegExp(
  r'\(([A-Za-z0-9_]{2,8})\)\s*([A-Za-z0-9\-\u2605]{1,8})?',
);

/// `[LEA]` - the same idea in square brackets.
final _bracketPrinting = RegExp(
  r'\[([A-Za-z0-9_]{2,8})\]\s*([A-Za-z0-9\-]{1,8})?',
);

/// `*F*` or `*f*`, and the word foil on its own.
final _foil = RegExp(r'\*[fF]\*|\bfoil\b', caseSensitive: false);

/// Reads a pasted list.
ParsedList parseList(String text) {
  final entries = <ListEntry>[];
  final rejected = <ListRejection>[];
  final sections = <String>[];
  final lines = text.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final lineNumber = i + 1;
    var line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('//') || line.startsWith('#')) continue;
    // Bullets and numbered-list markers from a chat message.
    line = line.replaceFirst(RegExp(r'^[-*\u2022]\s+'), '');
    if (line.isEmpty) continue;

    final bare = line.replaceAll(':', '').trim().toLowerCase();
    if (_sections.contains(bare)) {
      sections.add(line.replaceAll(':', '').trim());
      continue;
    }

    var quantity = 1;
    var name = line;
    final lead = _leading.firstMatch(line);
    if (lead != null) {
      quantity = int.parse(lead.group(1)!);
      name = lead.group(2)!.trim();
    } else {
      final trail = _trailing.firstMatch(line);
      if (trail != null) {
        name = trail.group(1)!.trim();
        quantity = int.parse(trail.group(2)!);
      }
    }

    final foil = _foil.hasMatch(name);
    name = name.replaceAll(_foil, ' ').trim();

    String? setCode;
    String? number;
    final paren = _parenPrinting.firstMatch(name);
    if (paren != null) {
      setCode = paren.group(1);
      number = paren.group(2);
      name = name.substring(0, paren.start).trim();
    } else {
      final bracket = _bracketPrinting.firstMatch(name);
      if (bracket != null) {
        setCode = bracket.group(1);
        number = bracket.group(2);
        name = name.substring(0, bracket.start).trim();
      }
    }

    // Brackets are left alone on purpose. Real cards carry them - `Erase (Not
    // the Urza's Legacy One)` is a card, not a card called Erase - so stripping
    // every parenthesised group would quietly truncate real names to make fake
    // ones look tidy. A set code followed the pattern and was taken; anything
    // else stays, and a line that then matches nothing is reported rather than
    // guessed at.
    name = name.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    // A trailing comma or full stop from prose.
    name = name.replaceAll(RegExp(r'[,.;]+$'), '').trim();

    // A line that is only a number is a stray - a mis-copied quantity, a
    // list marker - and no card is named "4". Importing one would put a
    // phantom entry in the collection that could never be matched to a price.
    final isBareNumber = RegExp(r'^\d+$').hasMatch(name);
    if (name.isEmpty || quantity <= 0 || isBareNumber) {
      rejected.add(ListRejection(line: lineNumber, text: raw.trim()));
      continue;
    }
    entries.add(
      ListEntry(
        quantity: quantity,
        name: name,
        line: lineNumber,
        setCode: setCode,
        collectorNumber: number,
        foil: foil,
      ),
    );
  }

  return ParsedList(entries: entries, rejected: rejected, sections: sections);
}
