import 'package:arcanum/core/platform/storage_durability.dart';

/// Nothing to ask: the vault on a phone is a file the app owns, and no browser
/// eviction policy reaches it.
///
/// See [requestPersistentStorage] in web_storage.dart for what this stands in
/// for. A phone never calls it - the call site is inside the branch that only
/// runs in a browser - and if one ever did, "there was no question to put" is
/// the truth about a platform with no navigator to ask.
Future<StorageDurability> requestPersistentStorage() async =>
    StorageDurability.unanswerable;
