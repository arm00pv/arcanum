import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/data/auth/account_service.dart';

/// The account service, where there is one to have.
///
/// Null on the phone, which keeps its vault on the device and has nobody to
/// sign in as or out of. Overridden at startup on the web, where the vault
/// belongs to an account and a collector needs a way to leave it - on a shared
/// laptop, a borrowed browser, or simply to hand the screen to someone else.
final Provider<AccountService?> accountServiceProvider =
    Provider<AccountService?>((Ref ref) => null);
