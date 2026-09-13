import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The notification topic this collector's companion publishes alerts to.
///
/// Derived from the backup token rather than stored as a second secret, so
/// there is exactly one thing to keep, one thing to re-paste on a new phone,
/// and no way for the phone and the server to disagree about the topic.
///
/// The derivation has to match the companion exactly. `check_alerts.py` builds
/// the same string from `~/arcanum/backup.token`, and
/// `test/backup/alert_topic_test.dart` pins both against a value worked out
/// independently of either.
///
/// A notification service's topic is the only thing protecting what is
/// published to it, which is why this is twenty hex characters of a hash of a
/// secret rather than something memorable like the collector's name.
String alertTopicFor(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) return '';
  final digest = sha256.convert(utf8.encode(trimmed)).toString();
  return 'arcanum-${digest.substring(0, 20)}';
}
