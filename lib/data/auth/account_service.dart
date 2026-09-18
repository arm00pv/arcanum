import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/data/auth/supabase_config.dart';

/// Something an account did that the collector needs told about, in words.
///
/// The service answers in its own vocabulary - "Invalid login credentials",
/// "Email not confirmed" - which is written for a developer reading a log. This
/// is the same fact written for the person who just typed their password.
class AccountError implements Exception {
  const AccountError(this.message);

  /// One sentence, already fit to show on screen.
  final String message;

  @override
  String toString() => message;
}

/// Who is signed in, and how they stop being.
///
/// The account half of the service, kept separate from everything that reads
/// cards: a vault that cannot reach the account server still opens, still
/// browses, and still values what is in it. Only the account screen needs this.
class AccountService {
  AccountService(this._client);

  final SupabaseClient _client;

  /// Opens the account connection. Called once, before the vault is drawn.
  static Future<AccountService> start() async {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
    return AccountService(Supabase.instance.client);
  }

  /// The signed-in account, or null.
  User? get user => _client.auth.currentUser;

  bool get isSignedIn => user != null;

  /// The address the confirmation link went to, when one is waiting.
  String? get pendingConfirmation => _pending;

  String? _pending;

  /// Fires on sign-in, sign-out and token refresh, so a screen never has to poll.
  Stream<AuthState> get changes => _client.auth.onAuthStateChange;

  /// Signs in with a password.
  Future<void> signIn({required String email, required String password}) async {
    _pending = null;
    try {
      await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    } on AuthException catch (error) {
      throw AccountError(_plainly(error));
    } catch (error) {
      debugPrint('[account] sign-in failed: $error');
      throw const AccountError(
        'Arcanum could not reach its server. Check the connection and try '
        'again.',
      );
    }
  }

  /// Creates an account.
  ///
  /// Returns true when the account is ready to use, and false when a
  /// confirmation link has been sent and has to be opened first - which is the
  /// normal case, and not a failure.
  Future<bool> signUp({required String email, required String password}) async {
    _pending = null;
    try {
      final AuthResponse response = await _client.auth.signUp(
        email: email.trim(),
        password: password,
      );
      if (response.session != null) return true;
      _pending = email.trim();
      return false;
    } on AuthException catch (error) {
      throw AccountError(_plainly(error));
    } catch (error) {
      debugPrint('[account] sign-up failed: $error');
      throw const AccountError(
        'Arcanum could not reach its server. Check the connection and try '
        'again.',
      );
    }
  }

  /// Sends the confirmation link again.
  Future<void> resendConfirmation(String email) async {
    try {
      await _client.auth.resend(type: OtpType.signup, email: email.trim());
    } on AuthException catch (error) {
      throw AccountError(_plainly(error));
    }
  }

  Future<void> signOut() async {
    _pending = null;
    await _client.auth.signOut();
  }

  /// The service's vocabulary, said plainly.
  static String _plainly(AuthException error) {
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
    return error.message;
  }
}
