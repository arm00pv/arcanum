import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/sync/account_changes.dart';
import 'package:arcanum/data/sync/account_collection.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/auth/account_reconcile.dart';

/// Brings down the changes another browser makes while this one is open.
///
/// A sign-in reconciles the account once, and [CollectionWatcher] carries this
/// browser's own work up for the rest of the session. Nothing brought anything
/// down, so a browser that was already open went on showing the collection as
/// it had been at its own sign-in: a card added on the laptop reached the
/// account in a second and the tablet that was already signed in never heard
/// about it, until somebody reloaded the page. The reload worked because it
/// re-ran the sign-in, and a sign-in pulls - which is the tell that the pull
/// was never the broken half. Nothing was asking for one.
///
/// Asked for by subscription rather than by asking more often. Polling is how
/// this gets fixed without a server that can speak first, and it buys an
/// unbroken stream of requests per device with nothing to say the great
/// majority of the time. The account can say when something has happened, so
/// the browser is told instead of asking, and a collection nobody is touching
/// costs nothing at all.
///
/// The change goes through the merge the pull already uses rather than a rule
/// of its own: [CollectionSync.mergeRow] is the same comparison a sign-in's pull
/// makes, so the later edit wins, a tie goes to the account, and a card removed
/// on another device arrives as a row with a deletion stamped on it and hides
/// the card here. A browser hearing about a change and a browser pulling one
/// cannot come out disagreeing about what the collection is, because there is
/// exactly one place where two copies of a holding are weighed and this file is
/// not it.
///
/// A holding arrives as an id, and an id is not a card. The catalogue behind a
/// collection is downloaded set by set, so a browser that has never opened the
/// set a printing came from holds the row and cannot name it: the card is drawn
/// as "--", and before this it went on being drawn as "--" for ever, because the
/// row merged and the screen was told and nothing ever went looking for the
/// printing. So the ids the arriving rows name are fetched here, through
/// [CatalogRepository.resolveMissingCards], which is the same fetch a sign-in
/// makes for the collection it has just brought down. Only what arrived is asked
/// about, and only what this browser is genuinely missing is requested, so two
/// browsers holding the same cards exchange a change and no catalogue traffic at
/// all.
///
/// The telling waits for that fetch rather than following it. A rebuild made
/// first draws the very placeholder being complained about, and the cards
/// arriving then rebuild the same list a second time to replace it - two
/// rebuilds for one change, the first of them thrown away. Waiting costs the
/// person reading nothing they would otherwise have seen: a row whose card is
/// already here is asked about, found, and announced on the tick it always was,
/// so the only rows that wait are the ones no rebuild could have drawn as a card
/// anyway. And nothing vanishes while it waits - the row was merged into the
/// collection the moment it arrived, and the announcement is made whether the
/// fetch answered, failed, or had nothing to ask for.
///
/// What is gathered up is the announcement, not the change. Every row lands as
/// it arrives - a merge is a query and a write, and a screen is pixels - and
/// the games that moved are told once per [settle], so a bulk import on another
/// device is a handful of rebuilds rather than one per card. Only the games that
/// changed are announced, which is what keeps a change in one vault from
/// rebuilding the vault being looked at.
///
/// Built only where there is an account to answer to - `main()` makes one inside
/// the branch that has one - so a phone, which keeps its vault to itself, holds
/// no socket and hears nothing.
class CollectionListener {
  CollectionListener({
    required this.sync,
    required this.changes,
    required this.catalog,
    required this.signedIn,
    required this.accountId,
    this.settle = const Duration(milliseconds: 250),
    this.retry = const Duration(seconds: 2),
    void Function(ProviderContainer scope, CardGame game) announce =
        announceCollectionChange,
  }) : _announce = announce;

  /// This device's side of the sync.
  final CollectionSync sync;

  /// The account's side: what it announces about its own holdings.
  final AccountChanges changes;

  /// This browser's catalogue: what turns the ids a row names into cards.
  ///
  /// The repository rather than some way of asking it for one card, because what
  /// makes the work affordable is that method's own two promises - a collection
  /// is narrowed to what actually arrived before anything is asked for, and a
  /// bulk import's ids reach the catalogue in one batch rather than one request
  /// apiece. A second way to fetch a card would be a second place for both of
  /// them to be forgotten.
  final CatalogRepository catalog;

  /// Whether there is an account to listen to.
  ///
  /// Asked afresh rather than established once, because the session this was
  /// started for can end underneath it, and a subscription opened for an
  /// account nobody is signed in to is not a sync - it is a request that can
  /// only be refused.
  final bool Function() signedIn;

  /// Which account, for the subscription's filter, or null while there is none.
  final String? Function() accountId;

  /// How long a run of incoming changes is gathered before the screens hear
  /// about it.
  ///
  /// A quarter of a second, and the two ends of that are the two things being
  /// weighed. The push side waits a whole second because it is weighing a
  /// network request; this is weighing a rebuild, and the collector is looking
  /// at the window the change came from, so it has to look immediate. What it
  /// has to absorb is the other end: a bulk import on another device arrives as
  /// one event per card, and a screen rebuilt for each of them is a screen
  /// nobody can read while it flickers.
  final Duration settle;

  /// How the screens are told. Held as a parameter so a test can count the
  /// tellings, which is the only way to see the coalescing at all.
  final void Function(ProviderContainer scope, CardGame game) _announce;

  /// How long to wait before asking again for a subscription that was not
  /// accepted, and the shortest and longest that wait is ever allowed to be.
  ///
  /// The reasons a subscription is not live divide in two and neither wants a
  /// fixed delay. A wire that dropped is back in a moment; a table the account
  /// will not stream is not coming back at all. So the wait starts short,
  /// because by far the common case is the first, and doubles towards something
  /// cheap enough to keep trying for as long as the tab is open.
  ///
  /// A parameter rather than a constant for the reason [CollectionWatcher]'s
  /// interval is one: a test that wants to see a second attempt should not have
  /// to wait for a backoff designed for a browser left open all evening.
  final Duration retry;

  static const Duration _longestWait = Duration(seconds: 30);

  Timer? _timer;
  Timer? _retry;
  ProviderContainer? _scope;

  /// Whether a subscription is wanted right now.
  ///
  /// The socket reports a channel it is being made to leave as a close, and a
  /// browser that has signed out must not answer that by asking for another
  /// one - so whether to reconnect is a fact this file keeps rather than
  /// something inferred from the last thing the socket said.
  bool _wanted = false;

  /// The games whose collection has changed here and have not been announced.
  final Set<CardGame> _changed = <CardGame>{};

  /// The printings those games' arriving rows named, and have not been fetched.
  ///
  /// Keyed by game because a fetch is: an id only means anything inside the
  /// catalogue it was minted in, and the two games' sources have nothing to say
  /// to each other.
  final Map<CardGame, Set<String>> _named = <CardGame, Set<String>>{};

  /// The merges still to happen, in the order the account announced them.
  Future<void> _queue = Future<void>.value();

  /// The fetches still to happen, and the tellings that follow them.
  ///
  /// A chain of its own rather than the merges' queue, and the length of a fetch
  /// is why: a catalogue answering for a set this browser has never downloaded
  /// is minutes of requests, and a merge waiting behind one would hold up every
  /// change behind that - including the rows that need no cards fetched for them
  /// at all.
  Future<void> _naming = Future<void>.value();

  bool _busy = false;
  Duration _wait = const Duration(seconds: 2);

  /// Starts listening, once there is a session to listen for.
  void begin(ProviderContainer scope) {
    _scope = scope;
    _wanted = true;
    _timer?.cancel();
    _timer = Timer.periodic(settle, (_) => _announceChanged());
    unawaited(_subscribe());
  }

  /// Stops listening, when the account goes away.
  ///
  /// Nothing is caught up on the way out. A sign-out happens after the session
  /// is already gone, so there is no account left to hear from - and the work
  /// done here stays in this browser's database, where the next sign-in
  /// reconciles it the way it reconciles everything else.
  void end() {
    _scope = null;
    _wanted = false;
    _timer?.cancel();
    _timer = null;
    _retry?.cancel();
    _retry = null;
    _wait = retry;
    _changed.clear();
    _named.clear();
    unawaited(changes.stop());
  }

  /// Asks the account to announce this account's holdings.
  Future<void> _subscribe() async {
    final String? id = accountId();
    if (!_wanted || id == null) return;
    try {
      await changes.listen(
        accountId: id,
        onRow: _arrived,
        onListening: _live,
        onLost: _lost,
      );
    } catch (error) {
      // The subscription could not even be asked for: a socket that will not
      // open, a client that was never configured, a network that refuses
      // websockets outright. None of it is fatal, and none of it is worth
      // stopping over - the app holds everything it held, the sign-in's pull
      // still runs, and the carrying up is the watcher's, which owes nothing to
      // this file.
      debugPrint('[realtime] the account is not announcing changes: $error');
      _lost(error);
    }
  }

  /// One change, as the account announces it.
  void _arrived(Map<String, Object?> row) {
    // Merged one at a time, in the order they were announced. A merge is a read
    // followed by a write, so two rows for the same holding merged side by side
    // could each compare against a collection the other had not written yet,
    // and the older of the two could end up in the database.
    _queue = _queue.then((_) => _merge(row)).catchError((Object error) {
      debugPrint('[realtime] a change did not land: $error');
    });
  }

  Future<void> _merge(Map<String, Object?> row) async {
    final CardGame? game = AccountCollection.gameOf(row);
    final String? cardId = AccountCollection.entry(row)?.cardId;
    if (game == null || cardId == null) return;
    // A row that lost its comparison is a holding this browser already had, and
    // it only ever got here by landing once before - through the sign-in's pull
    // or through this same path - which is what asked for its card at the time.
    if (!await sync.mergeRow(game, row)) return;
    _changed.add(game);
    _named.putIfAbsent(game, () => <String>{}).add(cardId);
  }

  /// The subscription is live, so everything missed while it was not is asked
  /// for.
  ///
  /// This fires on the first subscription as well as on every one after a
  /// connection that came back, and the first is not a wasted pass: a sign-in's
  /// pull and a socket's join are not the same instant, and a change made on
  /// another device between them has no other way in. A subscription that is
  /// merely reconnected has more than that to account for - the whole time the
  /// wire was down, which nothing replays.
  void _live() {
    _wait = retry;
    unawaited(_catchUp());
  }

  /// Brings down whatever the account has changed that this browser has not
  /// heard.
  ///
  /// A pull rather than a [CollectionSync.sync]: catching up is about what
  /// arrived, and what leaves is the push-side watcher's business on its own
  /// tick - it knows what this browser has carried up and this file does not.
  Future<void> _catchUp() async {
    final ProviderContainer? scope = _scope;
    if (_busy || scope == null || !signedIn()) return;
    _busy = true;
    try {
      for (final CardGame game in CardGame.values) {
        if (!signedIn()) break;
        try {
          final Set<String> named = await sync.pullChanged(game);
          if (named.isNotEmpty) {
            _changed.add(game);
            _named.putIfAbsent(game, () => <String>{}).addAll(named);
          }
        } catch (error) {
          debugPrint('[realtime] $game did not catch up: $error');
        }
      }
    } finally {
      _busy = false;
    }
  }

  /// The subscription is not live, so it is asked for again later.
  void _lost(Object error) {
    if (!_wanted) return;
    debugPrint('[realtime] the account stopped announcing changes: $error');
    _retry?.cancel();
    _retry = Timer(_wait, () => unawaited(_subscribe()));
    _wait = _wait * 2 > _longestWait ? _longestWait : _wait * 2;
  }

  /// Tells the screens about every game that has changed, once each.
  ///
  /// A tick with nothing gathered is a comparison and no work, which is what
  /// makes a timer that runs for the life of a session the cheapest way to
  /// write this: the alternative is arming a delay on the first change and
  /// cancelling it on the last, and a burst that never quite stops is a screen
  /// that never quite updates.
  ///
  /// Both what arrived and what those arrivals named are taken out here, at the
  /// tick, rather than read again when the fetch runs: a change landing while a
  /// slow catalogue is still answering the last one waits for the next tick
  /// instead of joining a batch already on its way out.
  void _announceChanged() {
    final ProviderContainer? scope = _scope;
    if (scope == null || _changed.isEmpty) return;
    final List<CardGame> games = _changed.toList();
    _changed.clear();
    _naming = _naming.then((_) => _fetchThenAnnounce(scope, games)).catchError((
      Object error,
    ) {
      debugPrint('[realtime] a change was not named: $error');
    });
  }

  /// Fetches the cards behind one run of arrivals, and then tells the screens.
  ///
  /// The order is the whole of it. [CatalogRepository.resolveMissingCards]
  /// first, so that the rebuild which follows has cards to draw rather than the
  /// placeholder this whole file is here to stop showing; the telling second,
  /// and unconditional, because the rows are already in the collection and a
  /// catalogue that did not answer must cost the collector the name of a card
  /// and nothing besides - the list they are reading goes on being exactly the
  /// list it was, with the row they just heard about on it.
  Future<void> _fetchThenAnnounce(
    ProviderContainer scope,
    List<CardGame> games,
  ) async {
    for (final CardGame game in games) {
      final List<String> named = (_named.remove(game) ?? const <String>{})
          .toList();
      try {
        if (named.isNotEmpty) await catalog.resolveMissingCards(game, named);
      } catch (error) {
        // One game's catalogue costs that game's cards and no other game's
        // telling, and costs nothing that was already written: the fetch stores
        // each batch as it arrives.
        debugPrint('[realtime] the cards behind $game did not arrive: $error');
      }
      // The session this run was started for can end while a set is coming
      // down - minutes of requests is minutes in which to sign out - and a
      // scope that has been let go of is not one to tell anything.
      if (_scope != scope) return;
      _announce(scope, game);
    }
  }
}
