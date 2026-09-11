import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/features/shell/home_shell.dart';
import 'package:arcanum/providers.dart';

/// The root widget.
///
/// Settings are a plain [ChangeNotifier], so the theme is rebuilt through a
/// [ListenableBuilder] rather than a provider — one less thing that can go
/// stale during startup.
class ArcanumApp extends ConsumerWidget {
  const ArcanumApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        );
      },
    );
  }
}
