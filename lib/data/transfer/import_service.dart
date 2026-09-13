import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/data/transfer/collection_transfer.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// How a row in an imported file was matched to a printing.
enum ImportMatch {
  byId('card id'),
  bySetAndNumber('set + number'),
  byName('name'),
  byNameNewest('name, newest printing');

  const ImportMatch(this.label);

  final String label;

  /// Whether the printing was inferred rather than stated by the file.
  bool get needsReview => this == ImportMatch.byNameNewest;
}

/// A row that has been matched to a real printing and is ready to be written.
class PlannedRow {
  const PlannedRow({
    required this.row,
    required this.card,
    required this.match,
    required this.mergesExisting,
    required this.existingQuantity,
  });

  final ImportRow row;
  final TcgCard card;
  final ImportMatch match;

  /// Whether a stack with the same physical identity is already owned, in which
  /// case the import adds to it rather than creating a second stack.
  final bool mergesExisting;
  final int existingQuantity;
}

/// Something wrong with one row, or with the file as a whole.
class ImportProblem {
  const ImportProblem(this.message, {this.row});

  final String message;
  final ImportRow? row;

  /// A message prefixed with the source line, for display.
  String get describe =>
      row == null ? message : 'Line ${row!.sourceLine}: $message';
}

/// What an import will do, computed before anything is written.
class ImportPlan {
  const ImportPlan({
    required this.game,
    required this.ready,
    required this.problems,
  });

  final CardGame game;
  final List<PlannedRow> ready;
  final List<ImportProblem> problems;

  /// Total physical cards the import will add.
  int get totalCards => ready.fold(0, (sum, r) => sum + r.row.quantity);

  /// Stacks that will be added to an existing entry.
  int get merging => ready.where((r) => r.mergesExisting).length;

  /// Stacks that will be created fresh.
  int get creating => ready.length - merging;

  /// Rows whose printing was inferred from the name alone.
  int get needingReview => ready.where((r) => r.match.needsReview).length;

  /// Total of the cost basis the file supplied, or null when it supplied none.
  double? get knownCost {
    var sum = 0.0;
    var any = false;
    for (final r in ready) {
      final price = r.row.purchasePrice;
      if (price != null) {
        sum += price * r.row.quantity;
        any = true;
      }
    }
    return any ? sum : null;
  }

  bool get isEmpty => ready.isEmpty && problems.isEmpty;
}

/// What an import actually did.
class ImportOutcome {
  const ImportOutcome({
    required this.cardsAdded,
    required this.stacksCreated,
    required this.stacksMerged,
    required this.failures,
  });

  final int cardsAdded;
  final int stacksCreated;
  final int stacksMerged;
  final List<ImportProblem> failures;

  bool get ok => failures.isEmpty;
}

/// A set's printings, indexed by collector number and by name.
class _SetIndex {
  _SetIndex(List<TcgCard> cards) {
    for (final card in cards) {
      byNumber.putIfAbsent(
        CollectionImporter.normaliseCollector(card.collectorNumber),
        () => card,
      );
      byName.putIfAbsent(TcgCard.normaliseName(card.name), () => card);
    }
  }

  final Map<String, TcgCard> byNumber = <String, TcgCard>{};
  final Map<String, TcgCard> byName = <String, TcgCard>{};
}

class _Hit {
  const _Hit(this.card, this.match);
  final TcgCard card;
  final ImportMatch match;
}

/// Resolves imported rows to printings and writes them into one game's
/// collection.
///
/// Matching is deliberately conservative. A row that names a set and a
/// collector number is matched exactly; a row that gives only a name is matched
/// to the newest printing of that name and flagged, because that is a real
/// ambiguity the user should see rather than a silent coin flip. A row that
/// matches nothing is reported and never guessed at.
class CollectionImporter {
  CollectionImporter({
    required CollectionRepository collection,
    required CatalogRepository catalogs,
  }) : _collection = collection,
       _catalogs = catalogs;

  final CollectionRepository _collection;
  final CatalogRepository _catalogs;

  /// Set indices built during one import run, keyed by lowercase set code.
  final Map<String, _SetIndex> _sets = <String, _SetIndex>{};

  CardGame get game => _collection.game;

  /// Normalises a collector number so `0161`, `161` and ` 161 ` agree.
  ///
  /// Only a number made purely of digits loses its leading zeros; suffixed and
  /// prefixed forms such as `161a` or `TG01` are kept intact, because there the
  /// zeros are part of the identity.
  static String normaliseCollector(String raw) {
    final s = raw.trim().toLowerCase().replaceAll(' ', '');
    if (s.isEmpty) return s;
    if (RegExp(r'^[0-9]+$').hasMatch(s)) {
      return s.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
    }
    return s;
  }

  /// Works out what [parsed] would do, without writing anything.
  Future<ImportPlan> plan(
    ParsedCollection parsed, {
    void Function(int done, int total)? onProgress,
  }) async {
    final problems = <ImportProblem>[
      for (final message in parsed.problems) ImportProblem(message),
    ];

    // Load every set the file references once, up front, so a large import does
    // not re-read the same set for every row.
    final wanted = <String>{
      for (final row in parsed.rows)
        if (row.setCode.isNotEmpty) row.setCode,
    };
    var loaded = 0;
    for (final setCode in wanted) {
      try {
        await _index(setCode);
      } catch (error) {
        problems.add(
          ImportProblem('Could not load set ${setCode.toUpperCase()}: $error'),
        );
      }
      loaded++;
      onProgress?.call(loaded, wanted.length);
    }

    final hits = <_Resolved>[];
    for (final row in parsed.rows) {
      final finish = _fitFinish(row.finish, problems, row);
      final condition = _fitCondition(row.condition, problems, row);
      final adjusted = finish == row.finish && condition == row.condition
          ? row
          : ImportRow(
              sourceLine: row.sourceLine,
              name: row.name,
              cardId: row.cardId,
              setCode: row.setCode,
              collectorNumber: row.collectorNumber,
              quantity: row.quantity,
              finish: finish,
              condition: condition,
              language: row.language,
              binder: row.binder,
              notes: row.notes,
              purchasePrice: row.purchasePrice,
              purchaseDate: row.purchaseDate,
            );

      final hit = await _resolve(adjusted);
      if (hit == null) {
        problems.add(
          ImportProblem(
            'no ${game.label} printing matches this row; skipped.',
            row: adjusted,
          ),
        );
        continue;
      }
      hits.add(_Resolved(adjusted, hit));
    }

    // Merge detection needs every resolved id at once.
    final existing = await _collection.entriesForCards(
      hits.map((h) => h.hit.card.id).toSet().toList(),
    );

    final ready = <PlannedRow>[];
    // One file can name the same physical stack more than once, and writing
    // merges those rows. The plan has to count them the same way, or it would
    // promise more new stacks than it actually creates.
    final planned = <String, int>{};
    for (final resolved in hits) {
      final row = resolved.row;
      final card = resolved.hit.card;
      final key = _identity(card.id, row);
      final owned = _matchExisting(
        existing[card.id] ?? const <CollectionEntry>[],
        row,
      );
      final alreadyPlanned = planned[key] ?? 0;
      ready.add(
        PlannedRow(
          row: row,
          card: card,
          match: resolved.hit.match,
          mergesExisting: owned != null || alreadyPlanned > 0,
          existingQuantity: (owned?.quantity ?? 0) + alreadyPlanned,
        ),
      );
      planned[key] = alreadyPlanned + row.quantity;
    }

    return ImportPlan(game: game, ready: ready, problems: problems);
  }

  /// Writes a plan into the collection.
  Future<ImportOutcome> apply(
    ImportPlan plan, {
    void Function(int done, int total)? onProgress,
  }) async {
    var cardsAdded = 0;
    var created = 0;
    var merged = 0;
    var done = 0;
    final failures = <ImportProblem>[];

    for (final planned in plan.ready) {
      final row = planned.row;
      try {
        await _collection.addCard(
          cardId: planned.card.id,
          finish: row.finish,
          condition: row.condition,
          language: row.language,
          quantity: row.quantity,
          purchasePrice: row.purchasePrice,
          purchaseDate: row.purchaseDate,
          binder: row.binder,
          notes: row.notes,
        );
        cardsAdded += row.quantity;
        if (planned.mergesExisting) {
          merged++;
        } else {
          created++;
        }
      } catch (error) {
        failures.add(ImportProblem('could not be added ($error).', row: row));
      }
      done++;
      onProgress?.call(done, plan.ready.length);
    }

    return ImportOutcome(
      cardsAdded: cardsAdded,
      stacksCreated: created,
      stacksMerged: merged,
      failures: failures,
    );
  }

  /// Forgets the cached set indices. Call between imports of different files.
  void reset() => _sets.clear();

  // ------------------------------------------------------------- internals

  Future<_SetIndex> _index(String setCode) async {
    final key = setCode.toLowerCase();
    final cached = _sets[key];
    if (cached != null) return cached;

    List<TcgCard> cards;
    try {
      cards = await _catalogs.cardsInSet(game, key);
    } catch (_) {
      // Offline, or the provider has no such set. Whatever is cached still
      // counts, so a failed fetch is not fatal on its own.
      cards = await _catalogs.cachedCardsInSet(game, key);
    }
    final index = _SetIndex(cards);
    _sets[key] = index;
    return index;
  }

  Future<_Hit?> _resolve(ImportRow row) async {
    final id = row.cardId;
    if (id != null && id.isNotEmpty) {
      final byId = await _catalogs.resolveCard(game, id);
      if (byId != null) return _Hit(byId, ImportMatch.byId);
    }

    if (row.setCode.isNotEmpty && row.collectorNumber.isNotEmpty) {
      final index = _sets[row.setCode];
      final hit = index?.byNumber[normaliseCollector(row.collectorNumber)];
      if (hit != null) return _Hit(hit, ImportMatch.bySetAndNumber);
      // The set was found but not this number; the name is still worth trying,
      // because a file can carry a stale set code.
      final byNameInSet = index?.byName[TcgCard.normaliseName(row.name)];
      if (byNameInSet != null) return _Hit(byNameInSet, ImportMatch.byName);
    }

    if (row.name.isEmpty) return null;
    return _byName(row.name);
  }

  /// Matches a bare card name, flagging it when the name is ambiguous.
  Future<_Hit?> _byName(String name) async {
    final wanted = TcgCard.normaliseName(name);
    if (wanted.isEmpty) return null;

    final found = await _catalogs.search(game, name, limit: 60);
    final exact = <TcgCard>[
      for (final card in found)
        if (TcgCard.normaliseName(card.name) == wanted) card,
    ];
    if (exact.isEmpty) return null;
    if (exact.length == 1) return _Hit(exact.first, ImportMatch.byName);

    // Several printings carry this name and the file did not say which. The
    // newest is the useful default, and the plan marks the row for review.
    exact.sort((a, b) {
      final left = a.releasedAt ?? DateTime.utc(1900);
      final right = b.releasedAt ?? DateTime.utc(1900);
      return right.compareTo(left);
    });
    return _Hit(exact.first, ImportMatch.byNameNewest);
  }

  /// Substitutes a finish the game actually has, reporting the change.
  CardFinish _fitFinish(
    CardFinish finish,
    List<ImportProblem> problems,
    ImportRow row,
  ) {
    if (game.finishes.contains(finish)) return finish;
    final fallback = game.finishes.first;
    problems.add(
      ImportProblem(
        'the finish "${finish.label}" does not exist in ${game.label}; recorded as ${fallback.label}.',
        row: row,
      ),
    );
    return fallback;
  }

  /// Substitutes a condition the game actually grades, reporting the change.
  CardCondition _fitCondition(
    CardCondition condition,
    List<ImportProblem> problems,
    ImportRow row,
  ) {
    if (game.conditions.contains(condition)) return condition;
    final fallback = CardCondition.nearMint;
    problems.add(
      ImportProblem(
        'the condition "${condition.label}" is not used in ${game.label}; recorded as Near Mint.',
        row: row,
      ),
    );
    return fallback;
  }

  /// The physical identity of a stack: the same key the DAO merges on.
  String _identity(String cardId, ImportRow row) =>
      '$cardId|${row.finish.code}|${row.condition.code}|'
      '${row.language}|${row.binder}';

  /// The existing entry a row would merge into, if there is one.
  CollectionEntry? _matchExisting(
    List<CollectionEntry> existing,
    ImportRow row,
  ) {
    for (final entry in existing) {
      if (entry.finish == row.finish &&
          entry.condition == row.condition &&
          entry.language == row.language &&
          entry.binder == row.binder) {
        return entry;
      }
    }
    return null;
  }
}

/// A row matched to a printing, held until merge detection can run.
class _Resolved {
  const _Resolved(this.row, this.hit);
  final ImportRow row;
  final _Hit hit;
}
