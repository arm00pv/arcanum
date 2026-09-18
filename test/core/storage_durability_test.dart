// What the app makes of what a browser says about keeping its data.
//
//   flutter test test/core/storage_durability_test.dart
//
// A browser is allowed to say no, and some of them have nothing to say at all:
// the Storage API is secure-context only, one browser answers the request with a
// permission prompt and another with a silent `false`. None of that is
// reachable from a test, so the deciding was kept apart from the asking and this
// asserts the deciding. What is at stake is not the catalogue but the boot:
// whatever comes back, the app has to carry on.

import 'package:arcanum/core/platform/storage_durability.dart';
import 'package:flutter_test/flutter_test.dart';

/// A browser that answers what a test tells it to, and remembers being asked.
class _Browser implements BrowserStorage {
  _Browser({this.already, this.granted, this.fails = false});

  /// What `persisted()` answers, or null for a browser without that question.
  final bool? already;

  /// What `persist()` answers, or null for a browser without that one.
  final bool? granted;

  /// Thrown instead of answering, which is what a browser with storage switched
  /// off does where the standard says it should answer.
  final bool fails;

  /// Whether the request was put at all.
  bool asked = false;

  @override
  Future<bool?> alreadyPersistent() async {
    if (fails) throw StateError('storage is switched off');
    return already;
  }

  @override
  Future<bool?> request() async {
    asked = true;
    if (fails) throw StateError('storage is switched off');
    return granted;
  }
}

void main() {
  test('a browser already keeping this origin is left alone', () async {
    // Asking again is not harmless: in the browser that answers the request
    // with a prompt, it is a dialog for a permission the origin already holds.
    // The granted: false here is what proves nothing was asked - an
    // implementation that asked anyway would come back evictable.
    final _Browser browser = _Browser(already: true, granted: false);

    expect(await askForDurableStorage(browser), StorageDurability.persistent);
    expect(browser.asked, isFalse);
  });

  test('a granted request means the data is kept', () async {
    expect(
      await askForDurableStorage(_Browser(already: false, granted: true)),
      StorageDurability.persistent,
    );
  });

  test('a refused request means the data is evictable', () async {
    // The ordinary answer on an iPhone in a tab, and not a failure: it is the
    // state the app shipped in before any of this existed.
    expect(
      await askForDurableStorage(_Browser(already: false, granted: false)),
      StorageDurability.evictable,
    );
  });

  test('a browser with no Storage API is not asked anything', () async {
    final _Browser browser = _Browser(already: null);

    expect(await askForDurableStorage(browser), StorageDurability.unanswerable);
    expect(browser.asked, isFalse);
  });

  test(
    'a browser missing only the request has nothing to answer with',
    () async {
      // Safari had estimate() and persisted() before it had persist(), and a
      // browser is free to have any part of the API and not the rest.
      expect(
        await askForDurableStorage(_Browser(already: false, granted: null)),
        StorageDurability.unanswerable,
      );
    },
  );

  test('a browser that throws does not take the app down with it', () async {
    final _Browser browser = _Browser(
      already: false,
      granted: false,
      fails: true,
    );

    expect(await askForDurableStorage(browser), StorageDurability.unanswerable);
  });
}
