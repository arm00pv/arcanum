import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/providers.dart';

/// Brings every game's collection into step with the account, and then fetches
/// the cards those holdings name.
///
/// Every game, not just the one on screen: a collector who signs in on a new
/// browser should find all of their vaults, not the one they happened to be
/// looking at. One query per game, once per sign-in.
///
/// The catalogue is a second pass rather than part of each game's sync. A
/// holding is one small row and lands in a moment; the cards behind a
/// collection are set downloads this browser may never have done, so a
/// collection pulled from the account arrives as rows that can only be shown as
/// "--". Syncing every game before resolving any of them is what stops the
/// first game's cards from holding up the rest of the account.
///
/// The game the collector has selected leads both passes. Nine games' holdings
/// are nine round trips, not free, whatever each one carries - a collector
/// whose game is Gundam used to wait for the whole of the account's holdings
/// and then eight other catalogues before their own screen had anything on it,
/// because Gundam is last in [CardGame.values] and Magic is first. Its rows are
/// asked for first and its cards are the first download started.
///
/// Leading in both passes rather than moving the catalogue pass ahead of the
/// holdings one: the holdings pass is what makes the rest of the account exist
/// on this browser at all, and running it to the end before any download begins
/// is still what stops one game's catalogue from holding up every other game's
/// rows. What the two orderings differ on is only how long the collector stares
/// at an empty screen, and leading in both passes is the shorter of the two.
///
/// A failure is logged and not thrown. The browser still holds everything it
/// held a moment ago, so a sync that did not happen is a delay rather than a
/// loss - and there is nothing here a collector could usefully do about it. The
/// same goes for a card that did not resolve: its row keeps the placeholder it
/// would have had anyway.
///
/// Every game is announced to the screens as it lands. None of this is awaited,
/// so the vault drew itself against a database this had not touched yet, and a
/// provider that has answered holds that answer until it is told the answer has
/// moved. Without the announcement, signing in on a new browser shows an empty
/// collection - or one of "--" - until somebody pulls the list down by hand,
/// which is exactly what a collector reads as the account having lost their
/// cards.
///
/// A game is announced whether or not its run finished, because both passes
/// write as they go: a connection that died half way still left this game's
/// collection different from the one the screens answered with. An
/// announcement that turns out to change nothing costs one query and no pixels,
/// since a screen being handed its own answer again goes on showing it while it
/// looks.
Future<void> reconcileAccount({
  required CollectionSync sync,
  required Bootstrap bootstrap,
  required ProviderContainer scope,
}) async {
  for (final CardGame game in _inSignInOrder(bootstrap.settings.activeGame)) {
    try {
      await sync.sync(game);
    } catch (error) {
      debugPrint('[sync] $game did not reconcile: $error');
    }
    announceCollectionChange(scope, game);
  }

  for (final CardGame game in _inSignInOrder(bootstrap.settings.activeGame)) {
    try {
      final List<String> owned = await bootstrap.collectionDao.ownedCardIds(
        game,
      );
      if (owned.isNotEmpty) {
        await bootstrap.catalog.resolveMissingCards(game, owned);
      }
    } catch (error) {
      debugPrint('[sync] $game cards did not resolve: $error');
    }
    announceCollectionChange(scope, game);
  }
}

/// Every game, with the one on screen at the front.
///
/// A rotation of [CardGame.values] rather than a list of its own: the same
/// games in the same order, each of them once, so leading with one costs the
/// others their place in the queue and nothing else. Asked for once per pass
/// rather than once for the run, because the two passes are seconds apart on a
/// real account and a collector who switches games while theirs arrives is
/// looking at the new game by the time the downloads begin.
List<CardGame> _inSignInOrder(CardGame active) => <CardGame>[
  active,
  for (final CardGame game in CardGame.values)
    if (game != active) game,
];

/// Tells the screens showing one game that its collection is not what they said.
///
/// The pair a pull-to-refresh invalidates, because a sign-in changes exactly
/// what a pull changes: the holdings themselves, and the catalogue data behind
/// them.
///
/// Shared with `CollectionWatcher`, which brings the account's copy down the
/// same way when it reconciles after a gap: what has to be announced is one
/// fact, and a second definition of it is a second thing to keep in step.
///
/// Per game rather than all at once, so the vault somebody is looking at is
/// readable while the rest of the account is still travelling. And per game
/// rather than per chunk of a catalogue download: a collection arrives in
/// dozens of chunks, and a list rebuilt for each of them is a list nobody can
/// read while it flickers.
void announceCollectionChange(ProviderContainer scope, CardGame game) {
  scope.invalidate(collectionOverviewProvider(game));
  scope.invalidate(ownedCardsProvider(game));
}
