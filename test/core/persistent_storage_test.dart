// The one call main() makes to ask a browser to keep the catalogue and the
// collection.
//
//   flutter test test/core/persistent_storage_test.dart
//   flutter test --platform chrome test/core/persistent_storage_test.dart
//
// The first run is a phone's: the stub answers, and all it establishes is that
// the call is there and is safe. The second is the one worth having - it
// compiles the JavaScript interop and puts the real question to a real browser,
// which is the only way web_storage_web.dart is exercised off a phone. It is
// also the one that did not finish when this was written: twice the run compiled
// the test, launched Chrome, and then said nothing for ten minutes, so the
// interop was proved by hand instead - see the section on it in
// docs/web-on-ios.md. Neither run can assert which way the browser decides,
// because that is a policy with no seam in it: it depends on the browser, on how
// often the site has been visited, and in Safari on whether the app was added to
// the Home Screen.

import 'package:arcanum/core/platform/storage_durability.dart';
import 'package:arcanum/core/platform/web_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('asking a browser to keep the data answers, and never throws', () async {
    expect(await requestPersistentStorage(), isIn(StorageDurability.values));
  });
}
