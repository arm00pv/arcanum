/// Asking a browser to keep this origin's data, as one exchange with it.
///
/// A seam rather than the interop itself, for the same reason the catalogue and
/// the account are seams rather than their clients: what has to be right here is
/// what the app makes of the answer, and that is not a thing to verify by
/// watching a browser. The browsers disagree about the request - one answers it
/// with a permission prompt, another with a silent `false`, a third has nothing
/// to answer it with at all - and none of them can be driven from a test. So
/// the asking is one file and the deciding is this one, where a test supplies a
/// browser that is already persistent, that refuses, or that throws instead of
/// answering, and reads back what was asked of it.
library;

import 'package:flutter/foundation.dart';

/// What a browser has said about keeping this origin's catalogue and collection.
///
/// Three answers where the API has two, because the two ways of being turned
/// down are not the same news. A browser that understood the request and said no
/// is a browser whose policy this origin has not earned: on an iPhone that is
/// what a tab gets, and the same code is answered the other way once the app has
/// been added to the Home Screen. A browser with no Storage API has refused
/// nothing - there was no question to put, and there is nothing there for
/// anybody to fix.
enum StorageDurability {
  /// This origin's data stays until somebody asks for it to go.
  persistent,

  /// The browser will delete this origin's data on its own terms: storage
  /// pressure, or a site nobody has opened for a week.
  evictable,

  /// There was no question to put. No Storage API at all - it is secure-context
  /// only, so a LAN address served over plain HTTP has none of it - or an API
  /// that threw rather than answered.
  unanswerable,
}

/// The browser's Storage API, as far as this app asks it anything.
///
/// Both answers are nullable, and null is not "no": it is a browser with no such
/// question, which is a browser this app has to keep working on rather than a
/// browser that has decided anything.
abstract interface class BrowserStorage {
  /// Whether this origin's data is already exempt from eviction.
  ///
  /// Asked before the request rather than after it, because the two are not the
  /// same question. An origin the browser is already keeping would otherwise be
  /// made to ask for something it already holds, and in a browser that answers
  /// by asking its user, that is a dialog for a permission the site has.
  Future<bool?> alreadyPersistent();

  /// The request itself, and the browser's answer to it.
  Future<bool?> request();
}

/// What this browser is, having asked it.
///
/// The order of the two questions is the decision: [BrowserStorage.alreadyPersistent]
/// comes first so that an origin the browser is already keeping is never made to
/// justify itself, and the request is made only where there is something left to
/// ask for.
///
/// Nothing on the browser's side of this is allowed to reach the caller as an
/// error. A refusal is an ordinary answer, a browser without the API is an
/// ordinary browser, and either way it is the app the collector already has: the
/// collection is on the account and the catalogue is on the provider, so a
/// storage the browser will not keep costs a download and not a card.
Future<StorageDurability> askForDurableStorage(BrowserStorage browser) async {
  try {
    final bool? already = await browser.alreadyPersistent();
    if (already == null) return StorageDurability.unanswerable;
    if (already) return StorageDurability.persistent;

    final bool? granted = await browser.request();
    if (granted == null) return StorageDurability.unanswerable;
    return granted ? StorageDurability.persistent : StorageDurability.evictable;
  } catch (error) {
    // Storage switched off by the collector, an opaque origin, a browser that
    // throws where the standard says it answers - all three are this app being
    // told nothing, and none of them is worth failing a boot over.
    debugPrint('[storage] the browser did not answer: $error');
    return StorageDurability.unanswerable;
  }
}
