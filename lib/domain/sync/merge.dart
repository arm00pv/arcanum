import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/backup/backup_archive.dart';

/// What one merged row is keyed by.
///
/// Two devices describing the same holding must agree on identity, or a merge
/// doubles the collection instead of adding to it. A card is the same card when
/// the game, the printing, the finish, the condition, the language and the
/// binder all match - which is also exactly the unique index the table carries.
const List<String> kEntryKey = <String>[
  'game',
  'card_id',
  'finish',
  'condition',
  'language',
  'binder',
];

/// A want is a want: one per printing per game, with no quantity to argue about.
const List<String> kWantedKey = <String>['game', 'card_id'];

/// An alert is the same alert when it watches the same thing the same way.
const List<String> kAlertKey = <String>[
  'game',
  'card_id',
  'finish',
  'kind',
  'threshold',
];

/// A price point is the same point when it is the same day from the same source.
const List<String> kHistoryKey = <String>['game', 'card_id', 'finish', 'date'];

/// One row a merge would change.
class MergeChange {
  /// Creates a change row.
  const MergeChange({
    required this.table,
    required this.action,
    required this.label,
    required this.from,
    required this.to,
  });

  /// Which table the row belongs to.
  final String table;

  /// add for a row the collector does not have, raise when a count goes up.
  final String action;

  /// How the row reads: a card and its printing, or a box.
  final String label;

  /// The count held before the merge.
  final int from;

  /// The count after it.
  final int to;

  @override
  String toString() => 'MergeChange($action, $label, $from to $to)';
}

/// What merging another device's data would do, worked out before it is done.
///
/// A merge is additive by construction: it never deletes, never lowers a count
/// and never overwrites a price the collector paid. Two phones that each hold
/// part of a collection end up with the union of the two, and the things a merge
/// refuses to do are as much a part of the promise as the things it does.
class MergePlan {
  /// Creates a plan.
  const MergePlan({
    required this.changes,
    required this.addedRows,
    required this.raisedRows,
    required this.unchangedRows,
    required this.remoteRows,
    required this.freshPricePoints,
    required this.remoteCreated,
    required this.remoteAppVersion,
  });

  /// The first few changes, for the collector to read before agreeing.
  final List<MergeChange> changes;

  /// Rows this device does not have.
  final int addedRows;

  /// Rows it has, whose count would go up.
  final int raisedRows;

  /// Rows both devices have, at the same count or higher here.
  final int unchangedRows;

  /// How many rows in the merged tables the other device's archive holds.
  final int remoteRows;

  /// Price points this phone never recorded, which a merge would add.
  final int freshPricePoints;

  /// When the other device made its archive.
  final DateTime? remoteCreated;

  /// The app version that wrote it.
  final String remoteAppVersion;

  /// Whether the merge would change any holding at all.
  bool get nothingToDo => addedRows == 0 && raisedRows == 0;

  /// One line saying what would happen.
  String get headline {
    if (remoteRows == 0) return 'The other device has nothing to add';
    if (nothingToDo) return 'Both devices already agree';
    final List<String> parts = <String>[
      if (addedRows > 0) '${Fmt.count(addedRows)} new',
      if (raisedRows > 0) '${Fmt.count(raisedRows)} with more copies',
    ];
    return 'This would add ${parts.join(' and ')}';
  }

  /// What a merge will not do, in the collector's own words.
  List<String> get notes => <String>[
    'Merging never removes anything and never lowers a count: a card on either '
        'device is a card you own.',
    'Where both devices hold the same printing, the higher count wins and the '
        'purchase price already on this phone is kept.',
    'The price snapshots of the other device are added to this one, because a '
        'history is the one thing that cannot be reconstructed later.',
    'Decks are not merged. A deck is a document, and two versions of it are a '
        'question about which one is right, not about arithmetic.',
  ];
}

/// Works out what merging [remote] into [local] would do.
///
/// Pure: it reads two archives and returns a plan, so what a collector is about
/// to agree to can be tested without a database, a network or a phone.
MergePlan planMerge(BackupArchive local, BackupArchive remote) {
  final List<MergeChange> changes = <MergeChange>[];
  var added = 0;
  var raised = 0;
  var unchanged = 0;
  var remoteRows = 0;

  void walk(
    String table,
    String Function(Map<String, Object?> row) keyOf,
    String Function(Map<String, Object?> row) label,
  ) {
    final List<Map<String, Object?>> incoming =
        remote.tables[table] ?? const <Map<String, Object?>>[];
    if (incoming.isEmpty) return;
    remoteRows += incoming.length;
    final Map<String, Map<String, Object?>> mine =
        <String, Map<String, Object?>>{
          for (final Map<String, Object?> row
              in local.tables[table] ?? const <Map<String, Object?>>[])
            keyOf(row): row,
        };
    for (final Map<String, Object?> row in incoming) {
      final Map<String, Object?>? have = mine[keyOf(row)];
      final int theirs = _count(row['quantity']);
      final int ours = have == null ? 0 : _count(have['quantity']);
      if (have == null) {
        added++;
        if (changes.length < 40) {
          changes.add(
            MergeChange(
              table: table,
              action: 'add',
              label: label(row),
              from: 0,
              to: theirs,
            ),
          );
        }
      } else if (theirs > ours) {
        raised++;
        if (changes.length < 40) {
          changes.add(
            MergeChange(
              table: table,
              action: 'raise',
              label: label(row),
              from: ours,
              to: theirs,
            ),
          );
        }
      } else {
        unchanged++;
      }
    }
  }

  walk('collection_entries', entryKeyOf, (row) => describeRow(row, remote));
  walk('sealed_products', sealedKeyOf, (row) => nameOf(row, 'Sealed product'));
  walk('wanted_cards', (row) => _joined(row, kWantedKey), _labelOfCard);
  walk('alerts', (row) => _joined(row, kAlertKey), _labelOfCard);

  return MergePlan(
    changes: changes,
    addedRows: added,
    raisedRows: raised,
    unchangedRows: unchanged,
    remoteRows: remoteRows,
    freshPricePoints: newPricePoints(local, remote),
    remoteCreated: remote.created,
    remoteAppVersion: remote.appVersion,
  );
}

/// How many price points the other device would contribute.
///
/// Counted separately from the holdings because they are not changes to what the
/// collector owns: they are days the collection had a value that this phone was
/// not running to record, which is what a second device is actually for.
int newPricePoints(BackupArchive local, BackupArchive remote) {
  final Set<String> mine = <String>{
    for (final Map<String, Object?> row
        in local.tables['price_history'] ?? const <Map<String, Object?>>[])
      '${_joined(row, kHistoryKey)}|${row['source']}',
  };
  var fresh = 0;
  for (final Map<String, Object?> row
      in remote.tables['price_history'] ?? const <Map<String, Object?>>[]) {
    final String k = '${_joined(row, kHistoryKey)}|${row['source']}';
    if (!mine.contains(k)) fresh++;
  }
  return fresh;
}

/// A row's own name, or a fallback when it has none.
String nameOf(Map<String, Object?> row, String fallback) {
  final String name = '${row['name'] ?? ''}'.trim();
  return name.isEmpty ? fallback : name;
}

/// The identity of one card holding, as stored.
String entryKeyOf(Map<String, Object?> row) => _joined(row, kEntryKey);

/// The identity of one sealed holding: its product id, or its name when it has
/// none because somebody typed it in.
String sealedKeyOf(Map<String, Object?> row) {
  final String productId = '${row['product_id'] ?? ''}';
  if (productId.isNotEmpty) return '${row['game']}|$productId';
  return '${row['game']}|${row['set_code']}|${row['name']}';
}

/// The identity of one row of a merged table, by that table's own rules.
///
/// One rule, in one place: the merge service and the plan that describes it must
/// agree about what "the same row" means, or a plan would promise one thing and
/// the merge would do another.
String rowKeyOf(String table, Map<String, Object?> row) {
  switch (table) {
    case 'collection_entries':
      return entryKeyOf(row);
    case 'sealed_products':
      return sealedKeyOf(row);
    case 'wanted_cards':
      return _joined(row, kWantedKey);
    case 'alerts':
      return _joined(row, kAlertKey);
    case 'price_history':
      return '${_joined(row, kHistoryKey)}|${row['source']}';
    case 'portfolio_snapshots':
      return '${row['game']}|${row['date']}';
    default:
      return '${row['id']}';
  }
}

/// A card, named by whichever device knows it.
String describeRow(Map<String, Object?> row, BackupArchive remote) {
  final String id = '${row['card_id'] ?? ''}';
  final List<Object?>? card = remote.cardIndex[id];
  final String name = card != null && card.isNotEmpty
      ? '${card[0]}'
      : (id.isEmpty ? 'A printing' : id);
  final String set = card != null && card.length > 1 ? '${card[1]}' : '';
  final String finish = '${row['finish'] ?? ''}';
  final String where = <String>[
    if (set.isNotEmpty) set.toUpperCase(),
    if (finish.isNotEmpty) finish,
  ].join(' / ');
  return where.isEmpty ? name : '$name - $where';
}

String _labelOfCard(Map<String, Object?> row) {
  final String id = '${row['card_id'] ?? ''}';
  return id.isEmpty ? 'something' : id;
}

String _joined(Map<String, Object?> row, List<String> key) =>
    key.map((String column) => '${row[column]}').join('|');

int _count(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}') ?? 1;
}
