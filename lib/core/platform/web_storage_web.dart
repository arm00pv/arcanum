import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'package:arcanum/core/platform/storage_durability.dart';

/// `navigator.storage`, or null where this browser has none.
///
/// Which is more than an old browser. The Storage API is secure-context only, so
/// the LAN address `tool/serve_web.dart` serves has no storage manager either,
/// and anything checked against that address is being checked without this.
@JS('navigator.storage')
external JSObject? get _storage;

/// The storage manager, as much of it as this app asks for.
///
/// Written out by hand rather than taken from a package because it is two
/// methods, and a web-only dependency is one the phone build resolves for
/// nothing.
extension type _StorageManager(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> persisted();

  external JSPromise<JSBoolean> persist();
}

/// Asks this browser to keep this origin's catalogue and collection, once.
///
/// Nothing waits for the answer, and nothing about it is put on screen. A
/// refusal is the state every browser was in before this existed, and on an
/// iPhone it is the ordinary answer for a tab - so saying so would be a warning
/// in front of every collector on every visit, about a state the app was built
/// to survive, with nothing for them to press: the one thing that changes
/// WebKit's mind is adding the app to the Home Screen, and no page can do that
/// for anybody. What is left is the log, which is the only place the answer can
/// still be acted on by somebody who can see it.
Future<StorageDurability> requestPersistentStorage() async {
  final StorageDurability durability = await askForDurableStorage(
    const _Browser(),
  );
  debugPrint('[storage] $durability');
  return durability;
}

/// The browser's own storage manager, as [BrowserStorage] asks it.
class _Browser implements BrowserStorage {
  const _Browser();

  @override
  Future<bool?> alreadyPersistent() =>
      _ask('persisted', (_StorageManager manager) => manager.persisted());

  @override
  Future<bool?> request() =>
      _ask('persist', (_StorageManager manager) => manager.persist());

  /// [name] is the browser's own name for the question, and [ask] is how it is
  /// put once the browser is known to have it.
  ///
  /// Asked by name first because the two methods did not arrive together - a
  /// browser may have `estimate` and `persisted` and no `persist` - and a
  /// method that is not there should come back as an answer of "nothing to ask"
  /// rather than as a TypeError thrown out of the page.
  static Future<bool?> _ask(
    String name,
    JSPromise<JSBoolean> Function(_StorageManager) ask,
  ) async {
    final JSObject? manager = _storage;
    if (manager == null) return null;
    if (!manager.hasProperty(name.toJS).toDart) return null;
    return (await ask(_StorageManager(manager)).toDart).toDart;
  }
}
