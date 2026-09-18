import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/app.dart';
import 'package:arcanum/core/platform/web_database.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/auth/account_service.dart';
import 'package:arcanum/data/catalog/catalog_table.dart';
import 'package:arcanum/data/catalog/supabase_catalog.dart';
import 'package:arcanum/data/sync/account_changes.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/features/auth/account_gate.dart';
import 'package:arcanum/features/auth/account_providers.dart';
import 'package:arcanum/features/auth/account_reconcile.dart';
import 'package:arcanum/features/auth/collection_listener.dart';
import 'package:arcanum/features/auth/collection_watcher.dart';
import 'package:arcanum/data/backup/backup_scheduler.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/providers.dart';

/// Which step of the startup the app is on, so the screen can say.
///
/// The phone opens its own SQLite in microseconds and reads preferences from
/// the platform, so this was never worth showing. A browser has to fetch a
/// WebAssembly build of SQLite and start a worker for it first, and a white
/// page is the one thing that tells a collector nothing - not whether the app
/// is starting, and not whether it has failed.
final ValueNotifier<String> bootStep = ValueNotifier<String>('');

/// Boots Arcanum.
///
/// The database and preferences are opened before the vault is shown, so no
/// screen has to render a half-initialised state. A boot screen is drawn first,
/// and a failure is drawn as itself rather than left as a blank page.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // A build that fails has to say so. A release build answers a broken widget
  // with a grey box and no words, which in a browser is indistinguishable from
  // a page that never loaded - and the one time it matters is the one time
  // nobody can open a console.
  ErrorWidget.builder = (FlutterErrorDetails details) => BootFailure(
    error: details.exceptionAsString(),
    detail: details.stack?.toString() ?? '',
  );
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('[arcanum] ${details.exceptionAsString()}');
    debugPrint('${details.stack}');
  };

  runApp(const BootScreen());

  try {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // A browser has no SQLite of its own and a phone has one built in. Said
    // before anything is opened, and the rest of the app never asks which.
    useWebDatabaseFactory();

    bootStep.value = 'opening the database';
    final database = await AppDatabase.open();

    bootStep.value = 'reading preferences';
    final settings = await AppSettings.load();

    // Where the account will be, filled in below for a browser. Declared here
    // because the catalogue is built before it is: whether the shared
    // catalogue may be read is asked at the moment of each call, and by then
    // this holds the service.
    AccountService? account;

    final bootstrap = Bootstrap.create(
      database: database,
      settings: settings,
      // A browser reads Lorcana from the shared catalogue, but only while
      // somebody is signed in and has left the switch in Settings alone. The
      // phone is handed neither of these, so it keeps the five card providers
      // and never constructs any part of the server path.
      sharedCatalog: kIsWeb
          ? () => SupabaseCatalog(
              game: CardGame.lorcana,
              // Read at the first query rather than here: the client exists
              // only once Supabase.initialize has run, which is after this.
              table: SupabaseCatalogTable(() => Supabase.instance.client),
            )
          : null,
      sharedCatalogAllowed: kIsWeb
          ? () => settings.serverCatalog && (account?.isSignedIn ?? false)
          : null,
    );

    // Android's scheduler is told what the collector chose before the vault is
    // drawn, so a backup promised days ago is already queued if it is due.
    bootStep.value = 'starting the backup schedule';
    await BackupScheduler.start();
    await BackupScheduler.apply(settings.backupCadence);

    // An account is asked for only where there is a service to ask. The phone
    // app has no accounts, keeps its vault on the phone, and never sees the
    // sign-in screen; a browser has nothing to keep a vault in, so it does.
    Widget app = const ArcanumApp();
    if (kIsWeb) {
      bootStep.value = 'checking your account';
      account = await AccountService.start();
      final AccountService service = account;
      // A confirmation link lands the browser here carrying the session in the
      // address. Read it before the gate decides what to show, so the link
      // finishes what it started instead of leaving the collector at a sign-in
      // screen wondering whether it worked.
      await service.completeRedirect(Uri.base);

      final CollectionSync collection = CollectionSync(
        table: SupabaseAccountTable(Supabase.instance.client),
        db: database.db,
      );
      // Signing in reconciles the account once; this is what keeps it current
      // for the rest of the session. Made here, inside the branch that has an
      // account, so nothing about it exists on a phone.
      final CollectionWatcher watcher = CollectionWatcher(
        sync: collection,
        signedIn: () => service.isSignedIn,
      );
      // The other half of the same promise. The watcher carries this browser's
      // work up to the account; this is what brings another browser's work
      // down without the collector having to reload the page. Made here, in the
      // branch that has an account, for the same reason the watcher is: a phone
      // keeps its vault to itself and has nobody to hear from.
      final CollectionListener listener = CollectionListener(
        sync: collection,
        changes: SupabaseAccountChanges(Supabase.instance.client),
        // The catalogue this browser already has, so a change announced from
        // another browser can be fetched as the card it names rather than left
        // on screen as a placeholder.
        catalog: bootstrap.catalog,
        signedIn: () => service.isSignedIn,
        accountId: () => service.user?.id,
      );
      app = AccountGate(
        service: service,
        onSignedIn: (ProviderContainer scope) async {
          await reconcileAccount(
            sync: collection,
            bootstrap: bootstrap,
            scope: scope,
          );
          // Only once the sign-in's own sync is done: two runs carrying the
          // same game up at once is work nobody asked for, and the watcher
          // knows what has been carried up precisely because that sync says so.
          watcher.begin(scope);
          // After the reconcile rather than alongside it, because the first
          // thing this does on a live subscription is pull every game, and a
          // second pass over a collection the sign-in is still writing would be
          // two passes racing for no gain. Nothing is missed by waiting: the
          // catch-up is a pull of the whole account as it stands at the moment
          // the subscription goes live, whenever that turns out to be.
          listener.begin(scope);
        },
        onSignedOut: () {
          watcher.end();
          listener.end();
        },
        child: app,
      );
    }

    runApp(
      ProviderScope(
        overrides: [
          bootstrapProvider.overrideWithValue(bootstrap),
          // Settings shows who is signed in and offers the way out, so the same
          // service the gate holds is handed to the tree.
          if (account != null)
            accountServiceProvider.overrideWithValue(account),
        ],
        child: app,
      ),
    );
  } catch (error, stack) {
    debugPrint('[boot] $error');
    debugPrint('$stack');
    runApp(BootFailure(error: '$error', detail: '$stack'));
  }
}

/// What is on screen while the app is still opening.
class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: Center(
        child: ValueListenableBuilder<String>(
          valueListenable: bootStep,
          builder: (BuildContext context, String step, _) => Text(
            step.isEmpty ? 'Arcanum is starting' : 'Arcanum: $step',
            textDirection: TextDirection.ltr,
            style: const TextStyle(color: Color(0xFFB9B9C6), fontSize: 16),
          ),
        ),
      ),
    ),
  );
}

/// What is on screen when the app could not open.
///
/// A blank page is indistinguishable from a slow one, so the failure says what
/// it was. Nothing here is shipped to a collector on a phone that works.
class BootFailure extends StatelessWidget {
  const BootFailure({super.key, required this.error, required this.detail});

  final String error;
  final String detail;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF1A0B0F),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Arcanum could not start',
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  color: Color(0xFFFF8A80),
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                error,
                textDirection: TextDirection.ltr,
                style: const TextStyle(color: Color(0xFFF2F2F7), fontSize: 14),
              ),
              const SizedBox(height: 16),
              SelectableText(
                detail,
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  color: Color(0xFF8E8E99),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
