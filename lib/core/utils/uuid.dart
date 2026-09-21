import 'dart:math';

/// The identity a device mints for something that has to travel.
///
/// A uuid version 4, from [Random.secure] because the account's identity for a
/// deck is generated always as identity and cannot be supplied by a client: the
/// device has to name its own decks before the account has ever seen them, and
/// two devices minting the same identity would fold two decks into one.
///
/// One function, called from one place in the app per moment an identity is
/// minted - the v16 migration, [DeckDao.createDeck], and the sync when it meets
/// a deck that arrived from an archive written before v16 and has no identity
/// yet. A second spelling of this rule, in SQL or anywhere else, would be a
/// second answer to what a deck is called on the wire, which is exactly the
/// mistake docs/catalogue-server-side.md section 2.3 is written to prevent.
///
/// This is the answer the design left open (docs/deck-sync.md section 8.6:
/// the uuid package, or twenty lines over Random.secure()). It is the twenty
/// lines rather than a new dependency, and it is the same handful of lines for
/// the sealed and wants tables that will want an identity later.
abstract final class Uuid {
  static final Random _random = Random.secure();

  /// A fresh version 4 uuid, lower case, in the 8-4-4-4-12 form.
  ///
  /// Version and variant are stamped rather than left to the random bits, so
  /// that anything which reads an identity - a database column, a person
  /// looking at a log, another client - can tell what kind of value it is.
  static String v4() {
    final List<int> bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final StringBuffer out = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) out.write('-');
      out.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}
