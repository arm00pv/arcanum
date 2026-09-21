import 'package:supabase_flutter/supabase_flutter.dart';

/// What the account announces about its own holdings, as the listening half of
/// the sync needs to hear it.
///
/// An interface rather than the socket itself, for the same reason the
/// account's table is one: what happens once a change has arrived - the merge,
/// the comparison against this device's copy, the telling of the screens - is
/// the part that has to be right, and a websocket is not a thing a test can be
/// relied on to have. Everything above this line is arithmetic on rows.
abstract interface class AccountChanges {
  /// Starts listening for one account's holdings.
  ///
  /// [onRow] is handed each change as the account holds the row afterwards. A
  /// removal arrives that way too: it is an edit to the row rather than the end
  /// of it, so what comes across for a card removed on another device is the
  /// same row with a deletion stamped on it.
  ///
  /// [onListening] is called every time the subscription goes live - the first
  /// time included, and again after a connection that dropped and came back.
  /// It is the only honest answer to "am I missing anything", because being
  /// subscribed is not true from the moment it is asked for: the account has to
  /// accept it, and a change made while it was being set up, or while the wire
  /// was down, is not replayed. Realtime announces what is happening; it has
  /// nothing to say about what already happened.
  ///
  /// [onLost] is called when the subscription stops being live for any reason
  /// other than [stop] - a connection that dropped, an account that would not
  /// accept the subscription, a token it refused.
  Future<void> listen({
    required String accountId,
    required void Function(Map<String, Object?> row) onRow,
    required void Function() onListening,
    required void Function(Object error) onLost,
  });

  /// Stops listening, and gives the connection back.
  ///
  /// The socket belongs to the account rather than to the app: a browser that
  /// has signed out holds no subscription, and a phone never opens one.
  Future<void> stop();
}

/// The real one, over the account service.
///
/// One table per instance, because one table is what a channel is: the filter
/// a subscription asks with is a column on the rows of one table, and the server
/// answers about the table it was asked about. Which table is therefore a
/// constructor argument rather than a constant - the collection's holdings are
/// one table and a deck is two, and each of those is heard by an instance of its
/// own that knows nothing about the others.
class SupabaseAccountChanges implements AccountChanges {
  SupabaseAccountChanges(this._client, {required this.table});

  final SupabaseClient _client;

  /// The table this instance asks the account to announce.
  final String table;

  /// The collection's holdings. One table, because a holding is one row.
  static const String collectionEntries = 'collection_entries';

  /// The two a deck is: the deck row itself - its name, its format, its notes
  /// and the mark that says it has been deleted - and the lines in it, which
  /// move independently of it and of each other.
  static const String decks = 'decks';
  static const String deckCards = 'deck_cards';

  /// The subscription that is live, or null while there is none.
  ///
  /// Kept so it can be handed back by name, and so a callback from one that has
  /// already been given back can be recognised and dropped. Leaving a channel
  /// is reported to its own callbacks as a close, and a listener that read that
  /// as a connection which had dropped would open a fresh subscription for an
  /// account that has just signed out.
  RealtimeChannel? _channel;

  @override
  Future<void> listen({
    required String accountId,
    required void Function(Map<String, Object?> row) onRow,
    required void Function() onListening,
    required void Function(Object error) onLost,
  }) async {
    await stop();

    final RealtimeChannel channel = _client.channel('$table:$accountId');
    _channel = channel;

    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: table,
      // This account's rows, asked for by name. Row level security already
      // decides what this browser may be told, and this is not a second copy of
      // that decision: it is what keeps every other account's changes from
      // crossing the wire only to be thrown away here.
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: accountId,
      ),
      callback: (PostgresChangePayload payload) => onRow(payload.newRecord),
    );

    channel.subscribe((RealtimeSubscribeStatus status, Object? error) {
      if (_channel != channel) return;
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          onListening();
        // A postgres_changes subscription can be accepted and then fail while
        // the server sets the replication up behind it - a stale token, a table
        // it will not stream - and that verdict arrives here as an error rather
        // than as a refusal to join. To the app the two are one fact: nothing
        // is arriving.
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.closed:
        case RealtimeSubscribeStatus.timedOut:
          onLost(error ?? 'the account stopped announcing changes');
      }
    });
  }

  @override
  Future<void> stop() async {
    final RealtimeChannel? channel = _channel;
    _channel = null;
    if (channel != null) await _client.removeChannel(channel);
  }
}

/// Two of the account's tables, heard through one subscription.
///
/// A deck is two tables and a browser has to hear about both of them: a rename
/// is a row in one and a card added to the deck is a row in the other, and a
/// listener told about only the first would show a deck whose contents are a
/// pull out of date. [AccountChanges.listen] names no table - it is about what
/// arrived rather than where from - so this is where the two are joined: every
/// row from either half reaches the same callback, and the subscription is
/// reported live only once *both* are.
///
/// That last part is the whole reason this is not just two calls to a listener
/// that ignores the difference. Everything missed is missed by both halves,
/// because a connection that dropped dropped the whole socket - so a catch-up is
/// worth running once, when the pair is live together, and not twice, once per
/// channel, the first of them over an account that is still half unheard.
///
/// A half that drops takes the pair with it: it is reported as lost straight
/// away, and it counts as live again only when both have said so, which is what
/// makes a reconnection run one catch-up rather than none.
class JoinedChanges implements AccountChanges {
  JoinedChanges(this._first, this._second);

  final AccountChanges _first;
  final AccountChanges _second;

  /// Whether each half has reported itself live since it was last lost.
  ///
  /// Kept here rather than inferred from the last thing a socket said, for the
  /// reason the listener keeps its own: a channel that is being given back
  /// reports a close of its own, and a close is not a connection that dropped.
  bool _firstLive = false;
  bool _secondLive = false;

  /// Whether a subscription is wanted at all, so a callback from a half that has
  /// already been given back is ignored rather than answered.
  bool _wanted = false;

  bool get _bothLive => _firstLive && _secondLive;

  @override
  Future<void> listen({
    required String accountId,
    required void Function(Map<String, Object?> row) onRow,
    required void Function() onListening,
    required void Function(Object error) onLost,
  }) async {
    _wanted = true;
    _firstLive = false;
    _secondLive = false;
    await _first.listen(
      accountId: accountId,
      onRow: onRow,
      onListening: () => _reported(true, onListening),
      onLost: (Object error) => _lost(true, error, onLost),
    );
    await _second.listen(
      accountId: accountId,
      onRow: onRow,
      onListening: () => _reported(false, onListening),
      onLost: (Object error) => _lost(false, error, onLost),
    );
  }

  /// One half is live. The pair is live the moment both are, and once - a
  /// channel that reports itself live again while its partner never dropped is
  /// not a second live subscription.
  void _reported(bool first, void Function() onListening) {
    if (!_wanted) return;
    final bool wasBoth = _bothLive;
    if (first) {
      _firstLive = true;
    } else {
      _secondLive = true;
    }
    if (_bothLive && !wasBoth) onListening();
  }

  /// One half is not live, so neither is the pair: a change made while a
  /// subscription is half up has no way in at all.
  void _lost(bool first, Object error, void Function(Object) onLost) {
    if (!_wanted) return;
    if (first) {
      _firstLive = false;
    } else {
      _secondLive = false;
    }
    onLost(error);
  }

  @override
  Future<void> stop() async {
    _wanted = false;
    _firstLive = false;
    _secondLive = false;
    await _first.stop();
    await _second.stop();
  }
}
