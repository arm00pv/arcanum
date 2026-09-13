// The topic a companion publishes price alerts to.
//
//   flutter test test/backup/alert_topic_test.dart
//
// The phone shows the collector a topic to subscribe to, and the companion
// publishes to one derived from the same token. If the two derivations ever
// drifted, the notifications would go somewhere nobody is listening and the app
// would confidently display the wrong string - a silent failure with no error
// to notice. So the derivation is pinned to a digest computed outside both.

import 'package:arcanum/data/backup/alert_topic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the topic is the hash the companion also computes', () {
    // sha256('abc') is a published value, so this pins the algorithm without
    // pinning either implementation to the other.
    expect(alertTopicFor('abc'), 'arcanum-ba7816bf8f01cfea4141');
  });

  test('it is stable, and a different token gives a different topic', () {
    expect(alertTopicFor('secret-token'), alertTopicFor('secret-token'));
    expect(alertTopicFor('secret-token'), isNot(alertTopicFor('other-token')));
  });

  test('surrounding whitespace is not part of the secret', () {
    expect(alertTopicFor('  abc\n'), alertTopicFor('abc'));
  });

  test('no token means no topic rather than a topic anyone could guess', () {
    expect(alertTopicFor(''), '');
    expect(alertTopicFor('   '), '');
  });

  test('the topic is a legal notification topic', () {
    // alphanumeric plus hyphen and underscore, up to 64 characters.
    expect(
      RegExp(r'^[-_A-Za-z0-9]{1,64}$').hasMatch(alertTopicFor('abc')),
      isTrue,
    );
  });
}
