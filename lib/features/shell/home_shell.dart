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

  /// The width at which the bar along the bottom becomes a rail down the side.
  ///
  /// Five destinations fit a phone's bottom edge and belong there - a thumb
  /// reaches them and they are out of the way of what is being read. The same
  /// five stretched across a desktop window become a row of buttons two hundred
  /// pixels apart, which is a toolbar rather than navigation, and they are
  /// further from the content than the mouse is. Past this width they move to
  /// the side, which is where a window that shape keeps its navigation.
  static const double _railBreakpoint = 900;

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
  }

  /// The five tabs, kept alive so scroll position survives a switch.
  Widget _tabs() => IndexedStack(
    index: _index,
    children: const [
      DashboardScreen(),
      SetsScreen(),
      CollectionScreen(),
      DecksScreen(),
      SearchScreen(),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bool wide = MediaQuery.sizeOf(context).width >= _railBreakpoint;

    if (!wide) {
      return Scaffold(
        body: Column(
          children: [
            SafeArea(bottom: false, child: const GameSwitcherBar()),
            Expanded(child: _tabs()),
          ],
        ),
        bottomNavigationBar: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.hairline)),
          ),
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _select,
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

    return Scaffold(
      body: Row(
        children: [
          ColoredBox(
            color: c.canvasDeep,
            child: SafeArea(
              right: false,
              child: NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                backgroundColor: Colors.transparent,
                indicatorColor: c.accent.withValues(alpha: 0.18),
                destinations: [
                  for (final d in _destinations)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selected, color: c.accent),
                      label: Text(d.label),
                    ),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: c.hairline),
          Expanded(
            child: Column(
              children: [
                SafeArea(bottom: false, child: const GameSwitcherBar()),
                Expanded(child: _tabs()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
