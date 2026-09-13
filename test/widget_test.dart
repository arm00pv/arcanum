import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

void main() {
  testWidgets('the Arcanum theme builds and renders a glass surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(dark: true),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: GlassCard(
              child: EmptyState(
                icon: Icons.diamond_outlined,
                title: 'Nothing here yet',
                message: 'Add a card to get started.',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.byType(GlassCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light and dark themes both build', (tester) async {
    for (final dark in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(dark: dark),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });
}
