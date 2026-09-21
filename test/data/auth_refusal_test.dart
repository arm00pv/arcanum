import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/data/auth/auth_refusal.dart';

/// The one part of signing in that needs no server.
///
/// These are the sentences GoTrue actually sends, taken from the live project
/// rather than invented. A translation table is worth a test for a reason that
/// has nothing to do with coverage: it fails silently. A refusal that stops
/// being recognised does not throw, it just reaches the screen in the words of
/// whoever wrote the server - which is exactly the state this file exists to
/// end.
void main() {
  group('a refusal is said plainly', () {
    test('the vocabulary GoTrue is known to use, each in its own words', () {
      const Map<String, String> known = <String, String>{
        'Invalid login credentials':
            'That email and password do not match an account.',
        'Email not confirmed':
            'That account still needs its confirmation link opened. Check '
                'your email.',
        'User already registered':
            'There is already an account with that email. Sign in instead.',
        'Password should be at least 6 characters.':
            'That password is too short. Six characters or more.',
        'email rate limit exceeded':
            'Too many attempts just now. Wait a minute and try again.',
        'Unable to validate email address: invalid format':
            'That does not look like an email address.',
      };
      known.forEach((String said, String plainly) {
        expect(
          AuthRefusal.plainly(AuthException(said, statusCode: '400')),
          plainly,
          reason: 'GoTrue says "$said"',
        );
      });
    });

    // The one refusal in the whole path that arrives as a 500, and the one
    // measured against the live project on 2026-09-21. It is not about
    // anything the collector typed, and GoTrue's own sentence says nothing
    // about what to do next.
    test('the mail refusal says what happened and what to try', () {
      final String plainly = AuthRefusal.plainly(
        const AuthException(
          'Error sending confirmation email',
          statusCode: '500',
          code: 'unexpected_failure',
        ),
      );
      expect(
        plainly,
        'The confirmation email could not be sent. Check the address is '
        'spelled correctly, and try again in a few minutes.',
      );
      expect(
        plainly,
        isNot(contains('unexpected_failure')),
        reason: 'the error code is for a log, not for a screen',
      );
    });

    test('the mail refusal is recognised whichever link was being sent', () {
      for (final String said in <String>[
        'Error sending confirmation email',
        'Error sending magic link',
        'Error sending recovery email',
      ]) {
        expect(
          AuthRefusal.plainly(AuthException(said, statusCode: '500')),
          contains('could not be sent'),
          reason: 'GoTrue says "$said"',
        );
      }
    });

    test('a server fault is not repeated to the collector', () {
      const String said = 'pg: connection pool exhausted';
      final String plainly = AuthRefusal.plainly(
        const AuthException(said, statusCode: '500'),
      );
      expect(plainly, isNot(contains(said)));
      expect(plainly, contains('problem just now'));
    });

    test('the mail refusal wins over the server-fault sentence', () {
      expect(
        AuthRefusal.plainly(
          const AuthException(
            'Error sending confirmation email',
            statusCode: '500',
          ),
        ),
        contains('spelled correctly'),
        reason: 'a more specific sentence is the more useful one',
      );
    });

    test('a 4xx with no sentence of its own is repeated rather than guessed at',
        () {
      const String said = 'some refusal nobody has translated yet';
      expect(
        AuthRefusal.plainly(const AuthException(said, statusCode: '400')),
        said,
        reason: 'inventing a sentence for an unknown refusal is worse than '
            'showing the one the server wrote',
      );
    });

    test('a refusal that carried no status at all is still repeated', () {
      const String said = 'AuthRetryableFetchException';
      expect(AuthRefusal.plainly(const AuthException(said)), said);
    });
  });
}
