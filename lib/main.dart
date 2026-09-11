import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/app.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/providers.dart';

/// Boots Arcanum.
///
/// The database and preferences are opened before the first frame so no screen
/// ever has to render a half-initialised state, and the whole object graph is
/// injected through a single provider override.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final database = await AppDatabase.open();
  final settings = await AppSettings.load();
  final bootstrap = Bootstrap.create(database: database, settings: settings);

  runApp(
    ProviderScope(
      overrides: [bootstrapProvider.overrideWithValue(bootstrap)],
      child: const ArcanumApp(),
    ),
  );
}
