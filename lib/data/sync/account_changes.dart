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
class SupabaseAccountChanges implements AccountChanges {
  SupabaseAccountChanges(this._client);

  final SupabaseClient _client;

  static const String _table = 'collection_entries';

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

    final RealtimeChannel channel = _client.channel('$_table:$accountId');
    _channel = channel;

    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: _table,
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
