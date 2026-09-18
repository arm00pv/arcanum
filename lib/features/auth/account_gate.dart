import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/data/auth/account_service.dart';
import 'package:arcanum/features/auth/sign_in_screen.dart';

/// Holds a vault behind an account, where there is an account to hold it behind.
///
/// It listens to the session rather than to the sign-in screen, so a session
/// that ends anywhere - a token that expires, a sign-out from Settings, a
/// confirmation link opened in another tab - closes the vault by itself. The
/// screen never has to tell the gate that it succeeded.
class AccountGate extends StatefulWidget {
  const AccountGate({
    super.key,
    required this.service,
    required this.child,
    this.onSignedIn,
  });

  final AccountService service;

  /// Called when a session appears, including one restored on launch.
  ///
  /// This is the moment the vault stops being this browser's and starts being
  /// the account's, so it is where the two are reconciled. Deliberately not
  /// awaited: a collection of a few thousand cards takes a moment to travel,
  /// and the collector should be looking at their cards while it does.
  final Future<void> Function()? onSignedIn;

  /// The vault, shown once somebody is signed in.
  final Widget child;

  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  late bool _signedIn = widget.service.isSignedIn;
  StreamSubscription<AuthState>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.changes.listen((AuthState state) {
      final bool signedIn = state.session != null;
      if (signedIn != _signedIn && mounted) {
        setState(() => _signedIn = signedIn);
        if (signedIn) {
          unawaited(widget.onSignedIn?.call() ?? Future<void>.value());
        }
      }
    });
    // A session restored on launch never fires a change, so the same work has
    // to be started here or a returning collector would sync never.
    if (_signedIn) {
      unawaited(widget.onSignedIn?.call() ?? Future<void>.value());
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _signedIn ? widget.child : SignInScreen(service: widget.service);
}
