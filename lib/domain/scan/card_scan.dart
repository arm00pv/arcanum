import 'package:arcanum/domain/models/card_game.dart';

/// One line of text a reader found, and where it sat in the picture.
///
/// Position is the whole reason this is not a plain string. Every card in every
/// one of these games prints its name at the top and its set and number at the
/// bottom, and a reader that knows that can tell the 'R' that means rare from
/// the 'R' that starts a card's name without guessing.
class ScannedLine {
  const ScannedLine(
    this.text, {
    required this.top,
    this.height = 0,
    this.confidence,
  });

  /// What the reader thought the line said.
  final String text;

  /// How far down the picture the line sits: 0 at the top edge, 1 at the bottom.
  final double top;

  /// The line's height, as a fraction of the picture. Bigger usually means the
  /// card's name, which is printed larger than anything else on it.
  final double height;

  /// The reader's own confidence, when it offers one.
  final double? confidence;

  /// Every line's text, in the order they were read.
  static List<String> textOf(Iterable<ScannedLine> lines) => <String>[
    for (final ScannedLine line in lines) line.text,
  ];
}

/// What a photograph of a card gave up.
///
/// Every field is optional and every one of them can be wrong: this is a
/// reading of a photograph, not a fact about a card. [isAddressable] is the
/// only claim worth acting on unlooked-at, and even then the screen shows what
/// was found before anything is written down.
class CardScan {
  const CardScan({
    this.setCode,
    this.collectorNumber,
    this.setSize,
    this.name,
    this.lines = const <String>[],
  });

  /// The set code, upper-cased, when one was read.
  final String? setCode;

  /// The collector number, as the catalogue stores it.
  final String? collectorNumber;

  /// How many cards the set holds, from the '117/279' printed on the card.
  final int? setSize;

  /// The card's name, as well as it could be read.
  final String? name;

  /// Every line the reader produced, so a person can see what it saw when the
  /// answer is wrong.
  final List<String> lines;

  /// True when the scan names one printing rather than a card.
  bool get isAddressable => setCode != null && collectorNumber != null;

  /// True when the picture gave up nothing at all.
  bool get isEmpty =>
      setCode == null && collectorNumber == null && name == null;

  @override
  String toString() =>
      'CardScan(set: $setCode, number: $collectorNumber, size: $setSize, '
      'name: $name)';
}

/// Rarity letters and language codes a card prints beside its number.
///
/// Neither is a set code and both are the same shape as one, so a reader that
/// does not know them reports a set called 'R'.
const Set<String> _notSetCodes = <String>{
  'C',
  'U',
  'R',
  'M',
  'S',
  'T',
  'L',
  'B',
  'P',
  'EN',
  'DE',
  'FR',
  'IT',
  'ES',
  'PT',
  'JP',
  'JA',
  'KO',
  'RU',
  'ZH',
  'CS',
};

/// Words that appear on a card and are never its name.
const Set<String> _notNames = <String>{
  'LEGENDARY',
  'BASIC',
  'TOKEN',
  'CREATURE',
  'INSTANT',
  'SORCERY',
  'ENCHANTMENT',
  'ARTIFACT',
  'LAND',
  'PLANESWALKER',
  'BATTLE',
  'TRAINER',
  'ENERGY',
  'ITEM',
  'CHARACTER',
  'ACTION',
  'LOCATION',
  'ILLUSION',
  'SPELL',
  'TRAP',
  'MONSTER',
};

/// '117/279', with the slash a reader may have made of it.
final RegExp _numberOverSize = RegExp(r'(\d{1,4})\s*[/|\\!lI]\s*(\d{1,4})');

/// '117 279', with the slash dropped altogether.
final RegExp _spacedPair = RegExp(r'\b(\d{1,4})\s+(\d{1,4})\b');

/// 'XLN • EN' - a set code, a mark, and a two-letter language.
final RegExp _bulletPair = RegExp(
  r'([A-Z][A-Z0-9]{1,5})\s*[•·*°⁕©®+]\s*([A-Za-z]{2})\b',
);

/// 'LOB-EN001', which is both the set and the number.
final RegExp _ygoCode = RegExp(r'\b([A-Z]{2,4})-([A-Z]{2,3})?(\d{3,4})\b');

/// What a set code, a language and a rarity are separated by on a card.
final RegExp _separators = RegExp(r'[\s•·*°⁕©®+]+');

/// A lower-case letter, which no set code has ever contained.
final RegExp _lowercase = RegExp(r'[a-z]');

/// Everything that is not a letter or a digit, so a token can be compared.
final RegExp _notToken = RegExp(r'[^A-Z0-9]');

final RegExp _token = RegExp(r'^[A-Z]{2,5}$');
final RegExp _language = RegExp(r'\b[A-Z]{2}\b');
final RegExp _manaTail = RegExp(r'\s+(?:\{[^}]{0,6}\}|[0-9WUBRGCXS]{1,6})$');
final RegExp _letters = RegExp(r'[A-Za-z]');
final RegExp _digit = RegExp(r'[0-9]');

/// A recogniser's two favourite mistakes, undone where it is safe to undo them.
///
/// An O for a zero and an l for a one only get corrected next to a digit: a
/// lone 'O' is a letter, and set codes such as 'EOS' and 'M21' are full of both.
String _fixDigits(String text) => text
    .replaceAllMapped(
      RegExp(r'([0-9])[oO](?=[^A-Za-z]|$)'),
      (Match m) => '${m.group(1)}0',
    )
    .replaceAllMapped(
      RegExp(r'([0-9])[lI](?=[^A-Za-z]|$)'),
      (Match m) => '${m.group(1)}1',
    );

/// Reads a card out of what a text recogniser saw.
///
/// Each game is read on its own terms, because each prints its identity
/// differently: Magic prints a set code and a number, Yu-Gi-Oh! prints one code
/// that is both ('LOB-EN001'), and Pokemon and Lorcana print a number and a set
/// symbol but no code at all. Passing [knownSetCodes] turns the reading from a
/// guess into a check - a token that matches a set the catalogue holds is worth
/// ten that merely look like one.
CardScan readCardText(
  List<ScannedLine> lines, {
  required CardGame game,
  Set<String> knownSetCodes = const <String>{},
}) {
  final cleaned = <ScannedLine>[];
  for (final ScannedLine line in lines) {
    final text = _tidy(line.text);
    if (text.isEmpty) continue;
    cleaned.add(
      ScannedLine(
        text,
        top: line.top,
        height: line.height,
        confidence: line.confidence,
      ),
    );
  }
  cleaned.sort((ScannedLine a, ScannedLine b) => a.top.compareTo(b.top));
  if (cleaned.isEmpty) return const CardScan();

  final known = <String>{
    for (final String code in knownSetCodes) code.trim().toUpperCase(),
  };

  return switch (game) {
    CardGame.mtg => _readMtg(cleaned, known),
    CardGame.yugioh => _readYugioh(cleaned),
    CardGame.pokemon || CardGame.lorcana => _readNumbered(cleaned),
  };
}

/// Magic: '117/279 R' on one line and 'XLN - EN' on the next.
CardScan _readMtg(List<ScannedLine> lines, Set<String> known) {
  final strip = _bottomStrip(lines);
  final allText = lines.map((ScannedLine l) => l.text).join('\n');

  // The bottom strip first, then the whole picture: '117/279' is only ever
  // printed at the bottom, but a tight crop can put it anywhere in the frame.
  final number =
      _numberIn(strip) ?? _numberOverSize.firstMatch(_fixDigits(allText));
  final size = number?.group(2);
  final code =
      _setCodeFrom(strip, known) ?? _bulletPair.firstMatch(allText)?.group(1);

  return CardScan(
    setCode: code,
    collectorNumber: number == null ? null : _normaliseNumber(number.group(1)!),
    setSize: size == null ? null : int.tryParse(size),
    name: _nameFrom(lines),
    lines: ScannedLine.textOf(lines),
  );
}

/// Yu-Gi-Oh!: one code that names both the set and the card's position in it.
CardScan _readYugioh(List<ScannedLine> lines) {
  final allText = _fixDigits(
    lines.map((ScannedLine l) => l.text).join('\n').toUpperCase(),
  );
  final match = _ygoCode.firstMatch(allText);
  if (match == null) {
    return CardScan(name: _nameFrom(lines), lines: ScannedLine.textOf(lines));
  }
  return CardScan(
    setCode: match.group(1),
    // The region in the middle ('EN') is a printing detail rather than a
    // position, and the catalogue stores the number without it.
    collectorNumber: _normaliseNumber(match.group(3)!),
    name: _nameFrom(lines),
    lines: ScannedLine.textOf(lines),
  );
}

/// Pokemon and Lorcana: a number and a set symbol, and no code at all.
///
/// The number is still worth having. It is enough on its own once a name was
/// read too, because a set holds one card of a given name at a given number,
/// and the catalogue can be asked for every printing of a name.
CardScan _readNumbered(List<ScannedLine> lines) {
  final strip = _bottomStrip(lines);
  final allText = lines.map((ScannedLine l) => l.text).join('\n');
  final match =
      _numberIn(strip) ?? _numberOverSize.firstMatch(_fixDigits(allText));
  final size = match?.group(2);

  return CardScan(
    // Never a set code from the picture: these games do not print one, and a
    // token that merely looks like one would send the lookup to a set the card
    // is not in.
    setCode: null,
    collectorNumber: match == null ? null : _normaliseNumber(match.group(1)!),
    setSize: size == null ? null : int.tryParse(size),
    name: _nameFrom(lines),
    lines: ScannedLine.textOf(lines),
  );
}

/// The '117/279' in the bottom strip, with the slash however it was read.
Match? _numberIn(List<ScannedLine> strip) {
  for (final ScannedLine line in strip.reversed) {
    // Read as printed first. Correcting a letter into a digit would turn the
    // 'l' a reader made of a slash into a one and run the two numbers together.
    final match =
        _numberOverSize.firstMatch(line.text) ??
        _spacedPair.firstMatch(line.text) ??
        _numberOverSize.firstMatch(_fixDigits(line.text)) ??
        _spacedPair.firstMatch(_fixDigits(line.text));
    if (match != null) return match;
  }
  return null;
}

/// The lines near the bottom of the picture, or the lowest one when nothing is.
///
/// A photograph usually has some desk around the card, so a fixed threshold is
/// a guess; falling back to the lowest line keeps a tight crop working.
List<ScannedLine> _bottomStrip(List<ScannedLine> lines) {
  final low = <ScannedLine>[
    for (final ScannedLine line in lines)
      if (line.top >= 0.72) line,
  ];
  return low.isNotEmpty ? low : <ScannedLine>[lines.last];
}

/// The set code, preferring one the catalogue actually holds.
///
/// The catalogue's own list is a check rather than a shortcut, and it is only
/// worth anything when a token is asked the right question. Two of them matter.
/// A set code is printed in capitals, so a word in a card's rules text is not
/// one however many letters it shares with a code: 'Add one mana of any color'
/// contains the whole of Phyrexia: All Will Be One's code, and a scan that
/// believes it files the card in the wrong set. And a code sits on the line that
/// carries the card's identity - the collector number, or the language - or on a
/// line of its own when the reader split that line in two, which is what it did
/// in the first real reading this ever had.
///
/// What is left is a guess, and it is deliberately timid. A card's artist is
/// printed on the same line as its set code, and 'ERIC' looks exactly like a set
/// code to anything that only checks the shape of a token - so a guess is only
/// allowed from a line that carries the number or the language, which is where a
/// set code always lives.
String? _setCodeFrom(List<ScannedLine> strip, Set<String> known) {
  final anchored = <String>[];
  final whole = <String>[];
  for (final ScannedLine line in strip) {
    final onIdentityLine =
        _language.hasMatch(line.text) ||
        _numberOverSize.hasMatch(_fixDigits(line.text)) ||
        _spacedPair.hasMatch(_fixDigits(line.text));
    final parts = <String>[
      for (final String raw in line.text.split(_separators))
        if (raw.trim().isNotEmpty) raw,
    ];
    for (final String raw in parts) {
      // Printed in capitals, or it is not a set code. 'one' as a card's rules
      // print it is the same token as 'ONE' as a set prints it, and only the
      // capitals tell them apart.
      if (_lowercase.hasMatch(raw)) continue;
      final token = raw.toUpperCase().replaceAll(_notToken, '');
      if (token.isEmpty) continue;
      if (onIdentityLine) anchored.add(token);
      if (parts.length == 1) whole.add(token);
    }
  }

  if (known.isNotEmpty) {
    for (final String token in anchored) {
      if (known.contains(token)) return token;
    }
    for (final String token in whole) {
      if (known.contains(token)) return token;
    }
  }
  for (final String token in anchored) {
    if (_notSetCodes.contains(token)) continue;
    if (_token.hasMatch(token)) return token;
  }
  for (final String token in whole) {
    if (_notSetCodes.contains(token)) continue;
    if (_token.hasMatch(token)) return token;
  }
  return null;
}

/// The card's name: the topmost line that could be one.
///
/// The name is printed at the top of every one of these cards, larger than
/// anything else on them, so the first plausible line is nearly always right
/// and the implausible ones are easy to rule out.
String? _nameFrom(List<ScannedLine> lines) {
  for (final ScannedLine line in lines) {
    if (line.top > 0.5) break;
    final candidate = _nameCandidate(line.text);
    if (candidate != null) return candidate;
  }
  return null;
}

/// One line, or null when it cannot be a card's name.
String? _nameCandidate(String raw) {
  // A reader often glues the mana cost onto the name: 'Revel in Riches 4B'.
  var text = raw.replaceAll(_manaTail, '').trim();
  text = text.replaceAll(RegExp(r'^[\s\d]+'), '').trim();
  text = text.replaceAll(RegExp(r'\s{2,}.*$'), '').trim();
  if (text.length < 3 || text.length > 60) return null;
  if (!_letters.hasMatch(text)) return null;
  final upper = text.toUpperCase();
  if (upper == text && _notNames.contains(upper)) return null;
  // A line that is mostly digits is a number, not a name.
  if (_digit.allMatches(text).length > text.length / 2) return null;
  return text;
}

/// A collector number as the catalogue stores it.
///
/// '007' and '7' are the same position to a collector, and the catalogue holds
/// whichever the provider printed with the leading zeros intact - so the digits
/// are kept exactly as read. Letters are kept too: Magic prints numbers such as
/// 'S123' and Yu-Gi-Oh! stores '001'.
String _normaliseNumber(String raw) =>
    raw.trim().replaceAll(RegExp(r'^[^0-9A-Za-z]+'), '');

/// Trims whitespace and the stray marks a recogniser leaves on a line.
String _tidy(String raw) {
  var text = raw.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ');
  text = text.replaceAll(RegExp(r'^[\s\-–—_.,:;|]+'), '');
  text = text.replaceAll(RegExp(r'[\s\-–—_.,:;|]+$'), '');
  return text.trim();
}
