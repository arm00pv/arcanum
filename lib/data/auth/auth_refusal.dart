import 'package:supabase_flutter/supabase_flutter.dart';

/// The account service's vocabulary, said plainly.
///
/// GoTrue answers in sentences written for a developer reading a log - "Invalid
/// login credentials", "Email not confirmed" - and the collector who just typed
/// their password is owed the same fact in their own words.
///
/// This is a file of its own rather than a private method on [AccountService]
/// because of what it is: a pure translation with no network in it. Every other
/// part of signing in can only be exercised against a server. This can be held
/// still by a test, and the case that made that worth doing is the last one
/// here - a refusal GoTrue writes for its own operator and not for a person.
abstract final class AuthRefusal {
  /// One sentence, already fit to show on screen.
  ///
  /// Every test is written against the phrase GoTrue actually sends rather
  /// than against a word it happens to contain, because the words overlap:
  /// "Password should be at least 6 characters" is matched by \`password\`, and
  /// so would a sentence about a password being wrong. The pairs below are the
  /// ones measured against the live project.
  static String plainly(AuthException error) {
    final String said = error.message.toLowerCase();
    if (said.contains('invalid login credentials')) {
      return 'That email and password do not match an account.';
    }
    if (said.contains('email not confirmed')) {
      return 'That account still needs its confirmation link opened. Check '
          'your email.';
    }
    if (said.contains('already registered') ||
        said.contains('already been registered')) {
      return 'There is already an account with that email. Sign in instead.';
    }
    if (said.contains('password') && said.contains('at least')) {
      return 'That password is too short. Six characters or more.';
    }
    if (said.contains('rate limit') || said.contains('too many')) {
      return 'Too many attempts just now. Wait a minute and try again.';
    }
    if (said.contains('valid email') || said.contains('invalid format')) {
      return 'That does not look like an email address.';
    }
    // The mail refusal, and the only place in this whole path that answers 500.
    //
    // GoTrue sends it when its mail provider will not accept the message, and
    // the reply does not say which of two very different things happened: the
    // address cannot receive mail at all, or sending is having a bad minute.
    // Both are worth saying, and neither is the collector's fault - so the
    // sentence names both and tells them what to try first. Measured on the
    // live project on 2026-09-21: an address at a reserved domain gets
    // \`{"code":500,"error_code":"unexpected_failure","msg":"Error sending
    // confirmation email"}\`, and signing up with it creates no account.
    if (said.contains('sending confirmation email') ||
        said.contains('sending magic link') ||
        said.contains('sending recovery email')) {
      return 'The confirmation email could not be sent. Check the address is '
          'spelled correctly, and try again in a few minutes.';
    }
    // Any other 5xx is the server's fault and nobody else's, and the sentence
    // that came with it was written for whoever reads the logs. Repeating it
    // tells the collector nothing they can use, so this says the true thing
    // instead.
    final String? status = error.statusCode;
    if (status != null && status.startsWith('5')) {
      return 'The account server had a problem just now. Try again in a '
          'minute.';
    }
    return error.message;
  }
}
