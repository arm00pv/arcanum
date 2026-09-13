import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/features/collection/collection_screen.dart';
import 'package:arcanum/features/dashboard/dashboard_screen.dart';
import 'package:arcanum/features/decks/decks_screen.dart';
import 'package:arcanum/features/search/search_screen.dart';
import 'package:arcanum/features/sets/sets_screen.dart';
import 'package:arcanum/features/shell/game_switcher.dart';

/// The five top-level destinations, plus the game switcher.
///
/// An [IndexedStack] keeps every tab alive, so scroll position survives a tab
/// switch — which matters a lot when browsing a thousand sets.
///
/// The game switcher sits above the tabs because it is not a filter: changing it
/// swaps the catalogue, the collection and the portfolio over to the other game
/// entirely. Its signature colour also tints the whole theme, so it is always
/// obvious which collection you are looking at.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _destinations =
      <({IconData icon, IconData selected, String label})>[
        (
          icon: Icons.diamond_outlined,
          selected: Icons.diamond_rounded,
          label: 'Vault',
        ),
        (
          icon: Icons.grid_view_outlined,
          selected: Icons.grid_view_rounded,
          label: 'Sets',
        ),
        (
          icon: Icons.layers_outlined,
          selected: Icons.layers_rounded,
          label: 'Collection',
        ),
        (
          icon: Icons.style_outlined,
          selected: Icons.style_rounded,
          label: 'Decks',
        ),
        (
          icon: Icons.search_outlined,
          selected: Icons.search_rounded,
          label: 'Search',
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return Scaffold(
      body: Column(
        children: [
          SafeArea(bottom: false, child: const GameSwitcherBar()),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: const [
                DashboardScreen(),
                SetsScreen(),
                CollectionScreen(),
                DecksScreen(),
                SearchScreen(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            if (i == _index) return;
            setState(() => _index = i);
          },
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selected, color: c.accent),
                label: d.label,
              ),
          ],
        ),
      ),
    );
  }
}
