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
  const AccountGate({super.key, required this.service, required this.child});

  final AccountService service;

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
      }
    });
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
