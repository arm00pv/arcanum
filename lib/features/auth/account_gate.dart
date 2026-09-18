import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  ///
  /// Handed the scope rather than a ref belonging to this screen, because the
  /// work it starts outlives the moment it was started: whatever it brings down
  /// has to be announced to the screens that already answered, and those are
  /// reachable from the scope and from nowhere that dies with a widget.
  final Future<void> Function(ProviderContainer container)? onSignedIn;

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
        if (signedIn) _start();
      }
    });
    // A session restored on launch never fires a change, so the same work has
    // to be started here or a returning collector would sync never.
    if (_signedIn) _start();
  }

  /// Starts the work a sign-in asks for, and does not wait for it.
  ///
  /// The scope is looked up rather than kept, and only once somebody is signed
  /// in: a gate showing the sign-in screen has no work to hand it to.
  void _start() {
    final Future<void> Function(ProviderContainer)? work = widget.onSignedIn;
    if (work == null) return;
    unawaited(work(ProviderScope.containerOf(context, listen: false)));
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
