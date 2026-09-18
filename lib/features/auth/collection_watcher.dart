import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/auth/account_reconcile.dart';

/// Carries up what a collector changes after they have signed in.
///
/// [reconcileAccount] runs once, at the moment a session appears, and until
/// this existed that was the only time anything travelled. Everything a
/// collector did afterwards went into this browser's own database and no
/// further, so the account went on holding the collection as it had been at the
/// last sign-in: a card added here was never heard of there, and a card removed
/// here was removed here. Signing in on a second browser then showed the two
/// changes exactly the wrong way round - the card that was gone still in the
/// collection, the card that had been added missing - which is what a collector
/// reports as the account having eaten the evening's work.
///
/// What is watched is the one thing every one of those paths already leaves
/// behind. A holding is never written without its `updated_at` being stamped -
/// by the collection DAO, by the lots DAO selling the last copy, by an import,
/// by a restore - so the newest stamp in a game is a question the database can
/// answer about all of them at once. There is no per-change call to remember
/// from a new screen or a new path, and a path added tomorrow is carried up
/// without anybody knowing this file exists.
///
/// Waiting and batching rather than sending on every change, and the difference
/// is not only the cost. A collector sorting a box changes the collection dozens
/// of times in a minute; one question every [interval] turns that into a request
/// or two carrying everything those changes added up to. Nothing has to be
/// queued either, and a queue is a thing that can be forgotten about, dropped,
/// or lost with the tab: the answer is read out of the table the collector's
/// work is already in.
///
/// Built only where there is an account to answer to - `main()` makes one inside
/// the branch that has one - so a phone, which keeps its vault to itself, has no
/// timer, makes no request and behaves exactly as it did.
class CollectionWatcher with WidgetsBindingObserver {
  CollectionWatcher({
    required this.sync,
    required this.signedIn,
    this.interval = const Duration(seconds: 10),
  });

  /// This device's side of the sync.
  final CollectionSync sync;

  /// Whether there is an account to carry anything to.
  ///
  /// Asked afresh before every pass rather than established once, because the
  /// session this was started for can end while it is working: a sign-out, or a
  /// token that expires, both leave a pass in flight, and a request sent to an
  /// account nobody is signed in to is an error rather than a sync.
  final bool Function() signedIn;

  /// How often the collection is looked at.
  ///
  /// Ten seconds is a collector's patience rather than a machine's: the other
  /// browser they are comparing against is being looked at by a person, and a
  /// minute of staleness is a minute of wondering whether the app is broken.
  /// What it costs when nothing has happened is one query.
  final Duration interval;

  Timer? _timer;
  ProviderContainer? _scope;
  bool _busy = false;

  /// Whether the account's copy can be trusted to be as old as this device
  /// believes.
  ///
  /// True until a pass has reached the account, and true again after one that
  /// did not. A push that failed is a device that has stopped hearing what the
  /// account holds, and the other browser may have edited the same holding while
  /// it was not listening - so the pass that follows reconciles the way a
  /// sign-in does, account's copy first, rather than writing over an edit it
  /// never read.
  bool _unsure = true;

  /// Starts watching, once there is a session to watch for.
  ///
  /// The scope is kept because a pass can find the account's copy of a holding
  /// newer than this browser's, and a screen that has already answered keeps
  /// that answer until it is told the answer has moved - the same telling a
  /// sign-in's sync does, for the same reason.
  ///
  /// A first pass is made straight away rather than after a whole [interval].
  /// It costs one query when the sign-in that called this has just reconciled
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
  /// Nothing is carried up on the way out. A sign-out happens after the session
  /// is already gone, so there is no account left to carry anything to - and
  /// there does not need to be one: the work stays in this browser's database,
  /// newer than the account's copy of it, and the next sign-in reconciles the
  /// two the way it reconciles everything else.
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
            announceCollectionChange(scope, game);
          } else {
            await sync.pushAhead(game);
          }
        } catch (error) {
          reached = false;
          debugPrint('[sync] $game did not carry up: $error');
        }
      }
      _unsure = !reached;
    } catch (error) {
      _unsure = true;
      debugPrint('[sync] the collection was not read: $error');
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
      // one, so it is best effort - and it is also why [interval] is short
      // enough that there is usually nothing left to carry.
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
