import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';

/// Translates between a holding on the phone and its row in the account.
///
/// The two tables are deliberately the same shape - the phone's columns were
/// the model for the account's - but they are not the same types. The phone
/// counts milliseconds since the epoch and calls a purchase date an integer;
/// Postgres wants an instant and a calendar day. Keeping that translation in
/// one place, and testing it without a network, is what stops a timezone from
/// quietly turning a purchase date into the day before.
abstract final class AccountCollection {
  /// The columns the account table's unique index is built on.
  ///
  /// A holding is one row per printing, finish, condition, language and binder,
  /// exactly as it is on the phone, so a push can upsert rather than guess
  /// whether two rows are the same card or two copies of it. That is what makes
  /// a push safe to repeat after a dropped connection.
  static const String conflictTarget =
      'user_id,game,card_id,finish,condition,language,binder';

  /// The payload for one holding.
  ///
  /// The owner is deliberately absent. The column defaults to `auth.uid()`, so
  /// the database fills it in from the session and a client can neither forget
  /// it nor claim to be somebody else.
  static Map<String, Object?> row(CollectionEntry entry, CardGame game) {
    final purchaseDate = entry.purchaseDate;
    final notes = entry.notes;
    final purchasePrice = entry.purchasePrice;

    return <String, Object?>{
      'game': game.id,
      'card_id': entry.cardId,
      'finish': entry.finish.code,
      'condition': entry.condition.code,
      'language': entry.language,
      'quantity': entry.quantity,
      'purchase_price': ?purchasePrice,
      if (purchaseDate != null) 'purchase_date': _day(purchaseDate),
      'binder': entry.binder,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      'for_trade': entry.forTrade,
      // Sent even when it is null, unlike every other absent value here. The
      // account writes an upsert as an insert ... on conflict do update of the
      // columns the payload names, so a key left out means "leave whatever is
      // there" - and what is there for a card being added back is the tombstone
      // that would keep it deleted forever. A present row has to say so.
      'deleted_at': entry.deletedAt?.toUtc().toIso8601String(),
      'created_at': entry.createdAt.toUtc().toIso8601String(),
      'updated_at': entry.updatedAt.toUtc().toIso8601String(),
    };
  }

  /// A holding read back out of the account, or null if the row is not one.
  ///
  /// A row whose card id is missing is not a holding, and saying so is better
  /// than inventing one: the card id is the only part of a holding that cannot
  /// be defaulted.
  static CollectionEntry? entry(Map<String, Object?> row) {
    final Object? cardId = row['card_id'];
    if (cardId is! String || cardId.isEmpty) return null;

    return CollectionEntry(
      cardId: cardId,
      finish: CardFinish.fromCode(row['finish'] as String?),
      condition: CardCondition.fromCode(row['condition'] as String?),
      language: (row['language'] as String?) ?? 'en',
      quantity: (row['quantity'] as num?)?.toInt() ?? 1,
      purchasePrice: (row['purchase_price'] as num?)?.toDouble(),
      purchaseDate: _parseDay(row['purchase_date']),
      binder: (row['binder'] as String?) ?? '',
      notes: row['notes'] as String?,
      forTrade: row['for_trade'] == true,
      deletedAt: row['deleted_at'] == null
          ? null
          : _parseInstant(row['deleted_at']),
      createdAt: _parseInstant(row['created_at']),
      updatedAt: _parseInstant(row['updated_at']),
    );
  }

  /// The game a row belongs to, or null when it names one this build cannot
  /// place.
  ///
  /// Read out of the row rather than known in advance, because a change arrives
  /// on its own with nothing to say which vault it belongs to. [CardGame.fromId]
  /// answers Magic for anything it does not recognise, which is the right
  /// default for a preference somebody edited by hand and the wrong one here: a
  /// row for a game this build has never heard of would be filed under Magic,
  /// and a new game shipped on the account would quietly put its holdings into
  /// a collection they are not in.
  static CardGame? gameOf(Map<String, Object?> row) {
    final Object? id = row['game'];
    if (id is! String) return null;
    for (final CardGame game in CardGame.values) {
      if (game.id == id) return game;
    }
    return null;
  }

  /// Which of the two copies of a holding is the one to keep.
  ///
  /// The later edit wins, and a tie goes to the account - it is the copy every
  /// device can see, so letting the local one win a tie would make two phones
  /// disagree about the same moment. The phone stamps its own edits when they
  /// happen, so in practice the two only tie when they hold the same edit.
  ///
  /// A removal is not a special case here, and that is the point of it being a
  /// timestamp on the row: deleting a card is an edit made at a moment, so it
  /// beats an older edit and loses to a newer one, which is exactly what
  /// re-adding the card is. Nothing in this file has to know it is looking at
  /// a tombstone.
  static bool accountWins(CollectionEntry local, Map<String, Object?> row) {
    final DateTime remote = _parseInstant(row['updated_at']);
    return !remote.isBefore(local.updatedAt);
  }

  /// A calendar day, the way Postgres writes one.
  static String _day(DateTime date) {
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  /// The day back again, at local midnight.
  ///
  /// A purchase date is a day, not a moment, so it is read as midnight local
  /// rather than midnight UTC - otherwise a card bought on the 3rd shows as the
  /// 2nd for anyone west of Greenwich.
  static DateTime? _parseDay(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final List<String> parts = value.split('-');
    if (parts.length != 3) return null;
    final int? year = int.tryParse(parts[0]);
    final int? month = int.tryParse(parts[1]);
    final int? day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  static DateTime _parseInstant(Object? value) {
    if (value is String) {
      final DateTime? parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toLocal();
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
