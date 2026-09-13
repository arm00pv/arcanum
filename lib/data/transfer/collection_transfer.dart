import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/transfer/csv.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A CSV layout Arcanum can read and write.
///
/// These are real, documented export shapes rather than invented ones, so a
/// file that leaves Arcanum can be pasted straight back into the service it came
/// from.
enum TransferDialect {
  arcanum('arcanum', 'Arcanum', 'Everything, including cost basis and binder'),
  moxfield('moxfield', 'Moxfield', 'Count, Name, Edition, Condition, Foil'),
  archidekt(
    'archidekt',
    'Archidekt',
    'Quantity, Name, Edition, Condition, Foil',
  ),
  generic('generic', 'Spreadsheet', 'Plain quantity, name, set and number');

  const TransferDialect(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;
}

/// Column names seen in the wild, mapped onto the fields Arcanum understands.
///
/// Every lookup tries each alias in order, so a "Collector Number" and a
/// "Card Number" both land on the same field.
const Map<String, List<String>> _aliases = <String, List<String>>{
  'cardId': <String>['card_id', 'card id', 'scryfall id', 'scryfall_id', 'id'],
  'name': <String>['name', 'card name', 'card', 'title'],
  'setCode': <String>[
    'set_code',
    'set code',
    'edition',
    'set',
    'setcode',
    'expansion',
    'set id',
  ],
  'collectorNumber': <String>[
    'collector_number',
    'collector number',
    'number',
    'card number',
    'cn',
  ],
  'quantity': <String>['quantity', 'count', 'qty', 'amount'],
  'finish': <String>['finish', 'foil', 'printing', 'variant', 'is foil'],
  'condition': <String>['condition', 'cond', 'grade'],
  'language': <String>['language', 'lang'],
  'binder': <String>[
    'binder',
    'location',
    'categories',
    'category',
    'tags',
    'deck',
  ],
  'notes': <String>['notes', 'note', 'comment', 'comments'],
  'purchasePrice': <String>[
    'purchase_price',
    'purchase price',
    'price',
    'cost',
    'buy price',
    'price paid',
  ],
  'purchaseDate': <String>[
    'purchase_date',
    'purchase date',
    'date',
    'acquired',
    'date acquired',
  ],
};

/// One row of an imported file, before it has been matched to a printing.
class ImportRow {
  const ImportRow({
    required this.sourceLine,
    required this.name,
    this.cardId,
    this.setCode = '',
    this.collectorNumber = '',
    this.quantity = 1,
    this.finish = CardFinish.nonfoil,
    this.condition = CardCondition.nearMint,
    this.language = 'en',
    this.binder = '',
    this.notes,
    this.purchasePrice,
    this.purchaseDate,
  });

  /// 1-based line in the source file, so problems can be pointed at.
  final int sourceLine;

  final String name;
  final String? cardId;
  final String setCode;
  final String collectorNumber;
  final int quantity;
  final CardFinish finish;
  final CardCondition condition;
  final String language;
  final String binder;
  final String? notes;
  final double? purchasePrice;
  final DateTime? purchaseDate;

  /// Whether this row carries enough identity to be matched confidently.
  bool get isIdentifiable =>
      (cardId != null && cardId!.isNotEmpty) ||
      (setCode.isNotEmpty && collectorNumber.isNotEmpty) ||
      name.isNotEmpty;
}

/// A parsed file plus the problems found while reading it.
class ParsedCollection {
  const ParsedCollection({
    required this.dialect,
    required this.rows,
    required this.problems,
  });

  final TransferDialect dialect;
  final List<ImportRow> rows;

  /// Human readable notes about rows that were skipped, in file order.
  final List<String> problems;

  bool get isEmpty => rows.isEmpty;
}

/// Reads collection CSV files.
abstract final class CollectionCsvReader {
  /// Sniffs the dialect from a header row.
  static TransferDialect detect(List<String> header) {
    final h = Csv.header(header);
    // Tradelist Count and Categories are unique to their services; "Edition"
    // alone is not, because Archidekt uses it too, so it is only a hint.
    if (h.containsKey('tradelist count') || h.containsKey('moxfield id')) {
      return TransferDialect.moxfield;
    }
    if (h.containsKey('archidekt id') || h.containsKey('categories')) {
      return TransferDialect.archidekt;
    }
    if (h.containsKey('card_id') || h.containsKey('market_value')) {
      return TransferDialect.arcanum;
    }
    if (h.containsKey('count') && h.containsKey('edition')) {
      return TransferDialect.moxfield;
    }
    return TransferDialect.generic;
  }

  /// Parses [text], optionally forcing a [dialect] instead of sniffing one.
  static ParsedCollection parse(String text, {TransferDialect? dialect}) {
    final table = Csv.parse(text);
    if (table.isEmpty) {
      return ParsedCollection(
        dialect: dialect ?? TransferDialect.generic,
        rows: const <ImportRow>[],
        problems: const <String>['The file is empty.'],
      );
    }

    final header = table.first;
    final resolved = dialect ?? detect(header);
    final columns = Csv.header(header);
    final problems = <String>[];
    final rows = <ImportRow>[];

    // A file with no recognisable name column cannot be imported: guessing
    // which column holds the card name would silently corrupt the collection.
    final nameColumn = _column(columns, 'name');
    final idColumn = _column(columns, 'cardId');
    final wantedNames = _aliases['name']!.join(', ');
    if (nameColumn == null && idColumn == null) {
      return ParsedCollection(
        dialect: resolved,
        rows: const <ImportRow>[],
        problems: <String>[
          'No card name column found. Looked for: $wantedNames.',
        ],
      );
    }

    for (var i = 1; i < table.length; i++) {
      final cells = table[i];
      final line = i + 1;
      if (cells.every((c) => c.trim().isEmpty)) continue;

      final name = _cell(cells, nameColumn) ?? '';
      final id = _cell(cells, idColumn);
      if (name.isEmpty && (id == null || id.isEmpty)) {
        problems.add('Line $line: no card name; skipped.');
        continue;
      }

      final quantity = _int(_cell(cells, _column(columns, 'quantity'))) ?? 1;
      if (quantity <= 0) {
        problems.add('Line $line: quantity is zero; skipped.');
        continue;
      }

      rows.add(
        ImportRow(
          sourceLine: line,
          name: name,
          cardId: id,
          setCode: (_cell(cells, _column(columns, 'setCode')) ?? '')
              .toLowerCase(),
          collectorNumber:
              _cell(cells, _column(columns, 'collectorNumber')) ?? '',
          quantity: quantity,
          finish: parseFinish(_cell(cells, _column(columns, 'finish')) ?? ''),
          condition: parseCondition(
            _cell(cells, _column(columns, 'condition')) ?? '',
          ),
          language: _language(_cell(cells, _column(columns, 'language'))),
          binder: _cell(cells, _column(columns, 'binder')) ?? '',
          notes: _cell(cells, _column(columns, 'notes')),
          purchasePrice: _money(
            _cell(cells, _column(columns, 'purchasePrice')),
          ),
          purchaseDate: _date(_cell(cells, _column(columns, 'purchaseDate'))),
        ),
      );
    }

    return ParsedCollection(dialect: resolved, rows: rows, problems: problems);
  }

  static int? _column(Map<String, int> header, String field) {
    for (final alias in _aliases[field] ?? const <String>[]) {
      final index = header[alias];
      if (index != null) return index;
    }
    return null;
  }

  static String? _cell(List<String> cells, int? index) {
    if (index == null || index >= cells.length) return null;
    final value = cells[index].trim();
    return value.isEmpty ? null : value;
  }

  static int? _int(String? raw) {
    if (raw == null) return null;
    return int.tryParse(raw.replaceAll(RegExp(r'[^0-9-]'), ''));
  }

  /// Reads a money column, tolerating currency symbols and thousands separators.
  static double? _money(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.,-]'), '');
    if (cleaned.isEmpty) return null;
    // "1,234.56" keeps the last separator as the decimal point.
    final normalised = cleaned.lastIndexOf(',') > cleaned.lastIndexOf('.')
        ? cleaned.replaceAll('.', '').replaceAll(',', '.')
        : cleaned.replaceAll(',', '');
    final value = double.tryParse(normalised);
    if (value == null || value < 0) return null;
    return value;
  }

  /// Reads a purchase date.
  ///
  /// ISO-8601 is preferred; a bare month/day/year is read the American way,
  /// which is how Moxfield, TCGplayer and Archidekt all write it.
  static DateTime? _date(String? raw) {
    if (raw == null) return null;
    final iso = DateTime.tryParse(raw);
    if (iso != null) return iso;
    final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(raw);
    if (m == null) return null;
    final month = int.parse(m.group(1)!);
    final day = int.parse(m.group(2)!);
    final year = int.parse(m.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  /// Maps a two-letter code, or an English language name, to ISO 639-1.
  static String _language(String? raw) {
    if (raw == null || raw.isEmpty) return 'en';
    final s = raw.trim().toLowerCase();
    if (s.length == 2 || s.length == 3) return s;
    const names = <String, String>{
      'english': 'en',
      'japanese': 'ja',
      'german': 'de',
      'french': 'fr',
      'italian': 'it',
      'spanish': 'es',
      'portuguese': 'pt',
      'korean': 'ko',
      'russian': 'ru',
      'chinese': 'zh',
      'chinese simplified': 'zh',
      'chinese traditional': 'zh',
    };
    return names[s] ?? 'en';
  }

  /// Reads a finish from the many spellings used across services.
  static CardFinish parseFinish(String raw) {
    final s = raw
        .trim()
        .toLowerCase()
        .replaceAll('_', ' ')
        .replaceAll('-', ' ');
    if (s.isEmpty) return CardFinish.nonfoil;
    if (s.startsWith('non') || s == 'normal' || s == 'nf') {
      return CardFinish.nonfoil;
    }
    // "reverse holo" and "1st edition holo" both contain "holo", so the more
    // specific treatments have to be tested before the generic one.
    if (s.contains('reverse')) return CardFinish.reverseHolofoil;
    if (s.contains('etched')) return CardFinish.etched;
    if (s.contains('1st') || s.contains('first edition')) {
      return s.contains('holo')
          ? CardFinish.firstEditionHolofoil
          : CardFinish.firstEdition;
    }
    if (s.contains('holo')) return CardFinish.holofoil;
    if (s.contains('foil')) return CardFinish.foil;
    return CardFinish.nonfoil;
  }

  /// Reads a condition from both the Magic and the Pokémon grade vocabularies.
  static CardCondition parseCondition(String raw) {
    final s = raw.trim().toLowerCase().replaceAll('_', ' ');
    switch (s) {
      case 'm':
      case 'mint':
        return CardCondition.mint;
      case 'nm':
      case 'near mint':
        return CardCondition.nearMint;
      case 'ex':
      case 'excellent':
        return CardCondition.excellent;
      case 'gd':
      case 'good':
        return CardCondition.good;
      case 'lp':
      case 'light played':
      case 'lightly played':
        return CardCondition.lightPlayed;
      case 'mp':
      case 'moderately played':
        return CardCondition.moderatelyPlayed;
      case 'hp':
      case 'heavily played':
        return CardCondition.heavilyPlayed;
      case 'pl':
      case 'played':
        return CardCondition.played;
      case 'po':
      case 'poor':
        return CardCondition.poor;
      case 'dmg':
      case 'damaged':
        return CardCondition.damaged;
    }
    return CardCondition.nearMint;
  }
}

/// One line of an exported file.
class ExportRow {
  const ExportRow({required this.entry, this.card, this.unitValue});

  final CollectionEntry entry;
  final TcgCard? card;

  /// Market value of one copy, when it is known.
  final double? unitValue;
}

/// Writes collection CSV files.
abstract final class CollectionCsvWriter {
  /// The header row for [dialect].
  static List<String> header(TransferDialect dialect) => switch (dialect) {
    TransferDialect.arcanum => <String>[
      'card_id',
      'name',
      'set_code',
      'set_name',
      'collector_number',
      'rarity',
      'finish',
      'condition',
      'language',
      'quantity',
      'purchase_price',
      'purchase_date',
      'binder',
      'notes',
      'market_value',
      'total_value',
    ],
    TransferDialect.moxfield => <String>[
      'Count',
      'Tradelist Count',
      'Name',
      'Edition',
      'Condition',
      'Language',
      'Foil',
      'Tags',
      'Collector Number',
    ],
    TransferDialect.archidekt => <String>[
      'Quantity',
      'Name',
      'Edition',
      'Condition',
      'Language',
      'Foil',
      'Collector Number',
      'Categories',
    ],
    TransferDialect.generic => <String>[
      'Quantity',
      'Name',
      'Set Code',
      'Collector Number',
      'Finish',
      'Condition',
      'Language',
      'Purchase Price',
      'Binder',
      'Notes',
    ],
  };

  /// Builds a complete file from [rows].
  static String build(TransferDialect dialect, List<ExportRow> rows) {
    final out = <List<String>>[header(dialect)];
    for (final row in rows) {
      out.add(_row(dialect, row));
    }
    return Csv.encode(out);
  }

  static List<String> _row(TransferDialect dialect, ExportRow row) {
    final e = row.entry;
    final card = row.card;
    final name = card?.name ?? e.cardId;
    final setCode = card?.setCode ?? '';
    final number = card?.collectorNumber ?? '';
    final finish = _finishLabel(e.finish);
    final condition = e.condition.short;
    final price = e.purchasePrice;
    final unit = row.unitValue;
    final total = unit == null ? null : unit * e.quantity;

    return switch (dialect) {
      TransferDialect.arcanum => <String>[
        e.cardId,
        name,
        setCode,
        card?.setName ?? '',
        number,
        card?.rarity ?? '',
        e.finish.code,
        e.condition.code,
        e.language,
        e.quantity.toString(),
        price == null ? '' : price.toStringAsFixed(2),
        e.purchaseDate == null ? '' : _isoDate(e.purchaseDate!),
        e.binder,
        e.notes ?? '',
        unit == null ? '' : unit.toStringAsFixed(2),
        total == null ? '' : total.toStringAsFixed(2),
      ],
      TransferDialect.moxfield => <String>[
        e.quantity.toString(),
        '',
        name,
        setCode.toUpperCase(),
        condition,
        e.language,
        finish,
        e.binder,
        number,
      ],
      TransferDialect.archidekt => <String>[
        e.quantity.toString(),
        name,
        setCode.toUpperCase(),
        condition,
        e.language,
        finish,
        number,
        e.binder,
      ],
      TransferDialect.generic => <String>[
        e.quantity.toString(),
        name,
        setCode.toUpperCase(),
        number,
        e.finish.code,
        e.condition.code,
        e.language,
        price == null ? '' : price.toStringAsFixed(2),
        e.binder,
        e.notes ?? '',
      ],
    };
  }

  /// The vocabulary Moxfield and Archidekt use for finishes.
  static String _finishLabel(CardFinish finish) => switch (finish) {
    CardFinish.nonfoil => 'nonfoil',
    CardFinish.foil => 'foil',
    CardFinish.etched => 'etched',
    CardFinish.holofoil => 'holo',
    CardFinish.reverseHolofoil => 'reverseholo',
    CardFinish.firstEdition => '1st edition',
    CardFinish.firstEditionHolofoil => '1st edition holo',
  };

  static String _isoDate(DateTime d) {
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }
}
