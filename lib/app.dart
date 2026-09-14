import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/data/backup/backup_worker.dart';
import 'package:arcanum/features/security/lock_gate.dart';
import 'package:arcanum/features/shell/home_shell.dart';
import 'package:arcanum/providers.dart';

/// The root widget.
///
/// Settings are a plain [ChangeNotifier], so the theme is rebuilt through a
/// [ListenableBuilder] rather than a provider — one less thing that can go
/// stale during startup.
class ArcanumApp extends ConsumerStatefulWidget {
  const ArcanumApp({super.key});

  @override
  ConsumerState<ArcanumApp> createState() => _ArcanumAppState();
}

class _ArcanumAppState extends ConsumerState<ArcanumApp>
    with WidgetsBindingObserver {
  /// Guards against the launch check and the resume check overlapping.
  bool _catchingUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: the catch-up uploads a file and must never delay
    // the app appearing.
    WidgetsBinding.instance.addPostFrameCallback((_) => _catchUp());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The background isolate writes the outcome of a scheduled run into its own
    // copy of the preferences, so the app re-reads them on the way back in
    // rather than showing a time it only thinks is current.
    unawaited(ref.read(settingsProvider).reload().then((_) => _catchUp()));
  }

  /// Backs up now if the last one is stale.
  ///
  /// The scheduled job and this are the same promise kept two ways: Android may
  /// defer the job for hours, and the collector opening the app is the one
  /// moment the app is certain to be running.
  Future<void> _catchUp() async {
    if (_catchingUp || !mounted) return;
    _catchingUp = true;
    try {
      await catchUpAutoBackup(
        settings: ref.read(settingsProvider),
        service: ref.read(backupServiceProvider),
      );
    } catch (_) {
      // runBackupWith already records the failure where Settings can show it.
    } finally {
      _catchingUp = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    // The active game's signature colour tints the whole app, so the Magic side
    // reads violet and the Pokémon side reads gold.
    final accent = ref.watch(activeGameProvider).accent;

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'Arcanum',
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: AppTheme.build(dark: false, accent: accent),
          darkTheme: AppTheme.build(dark: true, accent: accent),
          home: const HomeShell(),
          // The lock wraps the navigator, not the home screen, so a pushed card
          // page or an open sheet is behind the cover as well.
          builder: (BuildContext context, Widget? child) =>
              LockGate(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
