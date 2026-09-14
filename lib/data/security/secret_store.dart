import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Somewhere to keep the few secrets Arcanum holds.
///
/// The app has exactly two: the token its companion's backup route requires, and
/// the optional JustTCG key. Both used to sit in the same preferences file as the
/// theme choice, which is to say in plain text inside the app's data directory -
/// readable by anything that can read that directory, and carried off wholesale
/// by a device backup.
abstract class SecretStore {
  /// Reads a secret, or null when nothing has been stored under [key].
  Future<String?> read(String key);

  /// Stores a secret, replacing anything already there.
  Future<void> write(String key, String value);

  /// Forgets a secret.
  Future<void> delete(String key);
}

/// The phone's own keystore, through the flutter_secure_storage plugin.
///
/// On Android the value is encrypted with a key that is generated inside the
/// hardware-backed Keystore and cannot be exported from it, so a copy of the
/// app's data directory or of its preferences file holds nothing usable. On a
/// device with no keystore the plugin falls back to its own software key, which
/// is weaker but still not a plain text file.
class KeystoreSecretStore implements SecretStore {
  /// Wraps the plugin's storage, or a copy of it supplied by a test.
  const KeystoreSecretStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A store that keeps everything in memory, for tests and for the fallback path.
class MemorySecretStore implements SecretStore {
  /// Starts from a given set of secrets, if any.
  MemorySecretStore([Map<String, String>? initial])
    : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  /// When set, every write throws, standing in for a device whose keystore
  /// refuses to cooperate.
  bool refuseWrites = false;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    if (refuseWrites) throw StateError('the keystore refused');
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async => _values.remove(key);

  /// What is currently held, for assertions.
  Map<String, String> get values => Map<String, String>.unmodifiable(_values);
}
