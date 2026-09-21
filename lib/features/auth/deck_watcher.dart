import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/data/sync/deck_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/auth/account_reconcile.dart';

/// Carries up what a collector changes to their decks after they have signed in.
///
/// The deck half of the collection's watcher, and it exists for the same report
/// feature along: a deck built or edited in one browser reached that browser's
/// database and no further, so signing in on a second browser showed the decks
/// as they had been at the first one's last sign-in - a deck renamed in the
/// evening still carrying its old name, and a card added to it nowhere.
///
/// What is watched is the one thing every path already leaves behind. A deck is
/// never written without its `updated_at` being stamped - by the deck DAO on
/// every rename, on every card added, set, moved or removed - and a line is never
/// written without its own stamp, so "has anything here moved" is a question the
/// database answers about both tables at once. There is no per-change call to
/// remember from a new screen, and a path added tomorrow is carried up without
/// anybody knowing this file exists.
///
/// Waiting and batching rather than sending on every change, for the reason the
/// collection waits: a collector working on a deck for a minute changes it dozens
/// of times, and one question a second turns that into a request or two carrying
/// everything those changes added up to. Nothing is queued either, and a queue is
/// a thing that can be forgotten about, dropped, or lost with the tab: the answer
/// is read out of the tables the collector's work is already in.
///
/// Built only where there is an account to answer to - `main()` makes one inside
/// the branch that has one - so a phone, which keeps its decks to itself, has no
/// timer, makes no request and behaves exactly as it did.
class DeckWatcher with WidgetsBindingObserver {
  DeckWatcher({
    required this.sync,
    required this.signedIn,
    // A second, for the reason the collection watcher's is a second: the question
    // is a local one - the newest stamp per game, which SQLite answers out of an
    // index in microseconds - so asking it often costs nothing, and the network
    // request only happens when something has actually moved.
    this.interval = const Duration(seconds: 1),
  });

  /// This device's side of the sync.
  final DeckSync sync;

  /// Whether there is an account to carry anything to.
  ///
  /// Asked afresh before every pass rather than established once, because the
  /// session this was started for can end while it is working: a sign-out, or a
  /// token that expires, both leave a pass in flight, and a request sent to an
  /// account nobody is signed in to is an error rather than a sync.
  final bool Function() signedIn;

  /// How often the decks are looked at.
  final Duration interval;

  Timer? _timer;
  ProviderContainer? _scope;
  bool _busy = false;

  /// Whether the account's copy can be trusted to be as old as this device
  /// believes.
  ///
  /// True until a pass has reached the account, and true again after one that did
  /// not. A push that failed is a device that has stopped hearing what the
  /// account holds, and another browser may have edited the same deck while it
  /// was not listening - so the pass that follows reconciles the way a sign-in
  /// does, account's copy first, rather than writing over an edit it never read.
  bool _unsure = true;

  /// Starts watching, once there is a session to watch for.
  ///
  /// The scope is kept because a pass can find the account's copy of a deck newer
  /// than this browser's, and a screen that has already answered keeps that
  /// answer until it is told the answer has moved - the same telling a sign-in's
  /// sync does, for the same reason.
  ///
  /// A first pass is made straight away rather than after a whole [interval]. It
  /// costs one query when the sign-in that called this has just reconciled
  /// everything, and it is the pass that recovers a sign-in whose sync could not
  /// reach the account at all.
  void begin(ProviderContainer scope) {
    _scope = scope;
    WidgetsBinding.instance.addObserver(this);
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(flush()));
    unawaited(flush());
  }

  /// Stops watching, when the account goes away.
  ///
  /// Nothing is carried up on the way out, for the reason the collection carries
  /// nothing: a sign-out happens after the session is already gone, so there is
  /// no account left to carry anything to - and there does not need to be one.
  /// The work stays in this browser's database, newer than the account's copy of
  /// it, and the next sign-in reconciles the two the way it reconciles
  /// everything else.
  void end() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    _scope = null;
  }

  /// Carries up whatever the account has not been told, once.
  ///
  /// The same pass the timer makes. Called directly by the two moments that are
  /// not a tick: the app going away, and a test that would otherwise be a race
  /// against a clock.
  Future<void> flush() async {
    final ProviderContainer? scope = _scope;
    if (_busy || scope == null || !signedIn()) return;
    _busy = true;
    try {
      bool reached = true;
      for (final CardGame game in await sync.ahead()) {
        if (!signedIn()) break;
        try {
          if (_unsure) {
            await sync.sync(game);
            // Told once for the whole pass rather than once per game: every deck
            // provider watches one counter, so a game that only carried its own
            // work up has changed nothing a screen is showing.
            announceDeckChange(scope);
          } else {
            await sync.pushAhead(game);
          }
        } catch (error) {
          reached = false;
          debugPrint('[sync] $game decks did not carry up: $error');
        }
      }
      _unsure = !reached;
    } catch (error) {
      _unsure = true;
      debugPrint('[sync] the decks were not read: $error');
    } finally {
      _busy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // A tab that is being put away or closed is a tab that may not be running
      // by the time the next tick comes round, and the edit made a moment before
      // is the one a collector would notice missing. Nothing can wait for this
      // one, so it is best effort.
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(flush());
      // Losing focus is not leaving: a collector who clicks another window is
      // still looking at this one.
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }
}
