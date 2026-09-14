import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/data/security/app_lock.dart';
import 'package:arcanum/providers.dart';

/// Covers the whole app until the phone's owner has authenticated.
///
/// It wraps the navigator rather than the home screen, so a card detail page, a
/// sheet or a dialog is behind the cover too - an app that only locks its front
/// door is not locked.
///
/// The lock is the phone's own: a fingerprint, a face or the screen lock. There
/// is no Arcanum password, and deliberately so - a second credential is a second
/// thing to lose, and this database is protected by the device that holds it.
class LockGate extends ConsumerStatefulWidget {
  /// Wraps [child] in the lock.
  const LockGate({super.key, required this.child, this.auth});

  /// The app, as it would be without the lock.
  final Widget child;

  /// The device authentication to use. The real one unless a test says
  /// otherwise.
  final DeviceAuth? auth;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  late final DeviceAuth _auth = widget.auth ?? ref.read(deviceAuthProvider);

  /// Whether the cover is over the app right now.
  bool _locked = false;

  /// Whether a prompt is on screen, so the button cannot open two of them.
  bool _asking = false;

  /// Whether the last prompt came back without a match.
  bool _refused = false;

  /// When the app was last put in the background, so the grace period can be
  /// measured from it.
  DateTime? _pausedAt;

  /// What the device will ask for: a fingerprint, a face, or the screen lock.
  String _method = 'screen lock';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _locked = ref.read(settingsProvider).lockEnabled;
    unawaited(_learnMethod());
    if (_locked) {
      // After the first frame, so the cover is painted before the system prompt
      // takes the screen.
      WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _pausedAt = DateTime.now();
      case AppLifecycleState.resumed:
        final bool stale = shouldRelock(
          pausedAt: _pausedAt,
          now: DateTime.now(),
        );
        _pausedAt = null;
        if (!stale || !ref.read(settingsProvider).lockEnabled) return;
        setState(() {
          _locked = true;
          _refused = false;
        });
        unawaited(_ask());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

  Future<void> _learnMethod() async {
    final String method = await _auth.describe();
    if (!mounted) return;
    setState(() => _method = method);
  }

  Future<void> _ask() async {
    if (_asking) return;
    setState(() {
      _asking = true;
      _refused = false;
    });
    final bool ok = await _auth.authenticate('Unlock Arcanum');
    if (!mounted) return;
    setState(() {
      _asking = false;
      _locked = !ok;
      _refused = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    final c = context.c;

    return Material(
      color: c.canvas,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 132,
                  height: 132,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          c.accent.withValues(alpha: 0.22),
                          c.accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: Center(
                      child: Icon(_iconFor(_method), size: 44, color: c.accent),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Arcanum is locked', style: context.t.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Unlock with your $_method to see the collection.',
                  textAlign: TextAlign.center,
                  style: context.t.bodyMedium?.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _asking ? null : _ask,
                  icon: _asking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_iconFor(_method), size: 18),
                  label: Text(_asking ? 'Waiting for the phone' : 'Unlock'),
                ),
                if (_refused) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(
                    'The phone did not recognise you.',
                    textAlign: TextAlign.center,
                    style: context.t.bodySmall?.copyWith(color: c.warning),
                  ),
                ],
                const SizedBox(height: 30),
                Text(
                  'Your collection is on this phone and nowhere else. Arcanum '
                  'has no account and no password of its own; the lock is the '
                  'one your phone already uses, so nothing new can be forgotten '
                  'or leaked.',
                  textAlign: TextAlign.center,
                  style: context.t.labelSmall?.copyWith(
                    color: c.textTertiary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(String method) {
    switch (method) {
      case 'fingerprint':
        return Icons.fingerprint_rounded;
      case 'face':
        return Icons.face_rounded;
      case 'iris':
        return Icons.remove_red_eye_outlined;
      default:
        return Icons.lock_rounded;
    }
  }
}
