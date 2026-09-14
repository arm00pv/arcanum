import 'package:local_auth/local_auth.dart';

/// How long Arcanum may sit in the background before it asks again.
///
/// Long enough to answer a message, read the card you just scanned against
/// something else, or take a photograph of a card, and short enough that a phone
/// left on a table is not an open collection.
const Duration kLockGrace = Duration(seconds: 60);

/// Whether a locked app should ask again, given when it was last put down.
///
/// Pulled out of the widget so the rule can be tested without a platform
/// channel: an app that has never been backgrounded is not re-locked, and one
/// that was backgrounded for longer than the grace period is.
bool shouldRelock({
  required DateTime? pausedAt,
  required DateTime now,
  Duration grace = kLockGrace,
}) {
  if (pausedAt == null) return false;
  return now.difference(pausedAt) > grace;
}

/// The phone's own authentication, as Arcanum asks for it.
///
/// An interface rather than a direct call to the plugin so the screens that use
/// it can be tested, and so there is exactly one place in the app that decides
/// what "unlocked" means.
abstract class DeviceAuth {
  /// Whether this device can authenticate the user at all.
  Future<bool> get isAvailable;

  /// What the device will ask for, in the user's words: a fingerprint, a face,
  /// or the screen lock.
  Future<String> describe();

  /// Asks the device to authenticate the user, returning true when it did.
  ///
  /// Never throws for a cancelled prompt: a cancel is an answer, not an error.
  Future<bool> authenticate(String reason);
}

/// The real thing: Android's BiometricPrompt, or the screen lock behind it.
class LocalDeviceAuth implements DeviceAuth {
  /// Wraps the local_auth plugin.
  LocalDeviceAuth([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> get isAvailable async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      // A device with no biometric hardware and no screen lock reports through
      // an exception on some Android skins; either way the answer is no.
      return false;
    }
  }

  @override
  Future<String> describe() async {
    try {
      if (!await _auth.canCheckBiometrics) return 'screen lock';
      final List<BiometricType> kinds = await _auth.getAvailableBiometrics();
      if (kinds.contains(BiometricType.face)) return 'face';
      if (kinds.contains(BiometricType.iris)) return 'iris';
      if (kinds.contains(BiometricType.fingerprint)) return 'fingerprint';
      return 'screen lock';
    } catch (_) {
      return 'screen lock';
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // The screen lock is allowed through on purpose: a phone whose reader is
        // wet, gloved or broken must not lock its owner out of their own
        // collection. What is being protected is a database on this device, and
        // the device's own credential is the right bar for it.
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

/// A device that always says yes, for tests and for the web build.
class OpenDeviceAuth implements DeviceAuth {
  /// Creates an always-open stand-in.
  const OpenDeviceAuth();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<String> describe() async => 'nothing';

  @override
  Future<bool> authenticate(String reason) async => false;
}
