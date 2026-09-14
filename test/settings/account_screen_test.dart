// The account screen, without a companion to talk to.
//
//   flutter test test/settings/account_screen_test.dart
//
// The screen is data-in, pixels-out: everything it reads comes from providers,
// so a test can hand it a device list and look at what it draws. The
// distinction the screen exists to make is between a token of this phone's own,
// which can be revoked, and the server wide one, which cannot - so each case
// here is asserted from the words the screen uses for it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/identity/identity_service.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/features/settings/account_screen.dart';
import 'package:arcanum/providers.dart';

const String kPhone = 'pixel-7-pro';
const String kRoot = 'root-token-typed-in-by-hand';
const String kOwn = 'device-token-minted-for-this-phone';

/// One device row, with no dates: the screen falls back to a sentence of its
/// own for a companion that never recorded when a device was added.
SignedInDevice device(
  String label, {
  required bool current,
  DateTime? expires,
}) => SignedInDevice(
  label: label,
  created: null,
  lastSeen: null,
  expires: expires,
  current: current,
);

/// A companion that answers from memory and remembers what it was asked.
class FakeCompanion extends IdentityService {
  FakeCompanion({required super.settings, required this.answer});

  DeviceList answer;
  final List<String> mailed = <String>[];
  final List<String> revoked = <String>[];

  @override
  Future<DeviceList> look() async => answer;

  @override
  Future<bool> revoke(String label) async {
    revoked.add(label);
    answer = DeviceList(
      owner: answer.owner,
      invited: answer.invited,
      emailEnabled: answer.emailEnabled,
      devices: <SignedInDevice>[
        for (final SignedInDevice d in answer.devices)
          if (d.label != label) d,
      ],
    );
    return true;
  }

  @override
  Future<void> emailVaultLink({String to = ''}) async => mailed.add('vault');

  @override
  Future<void> emailBackup({String to = ''}) async => mailed.add('backup');
}

/// A companion's answer listing the phone itself, and [others] besides.
Future<FakeCompanion> pumpAccount(
  WidgetTester tester, {
  required String token,
  required bool mine,
  bool email = true,
  List<String> others = const <String>[],
  DateTime? expires,
}) async {
  // A surface tall enough that the whole screen is built: a ListView only
  // builds what fits, and the parts of this one worth asserting on - the email
  // buttons and the closing sentence - are the parts furthest down.
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // A memory store rather than the keystore: the real one is a plugin, and a
  // plugin call inside a widget test is a wait with nothing on the other end.
  final AppSettings settings = await AppSettings.load(
    secrets: MemorySecretStore(),
  );
  settings.backupEndpoint = 'https://example.com/arcanum';
  settings.backupToken = token;
  settings.deviceLabel = kPhone;
  final FakeCompanion companion = FakeCompanion(
    settings: settings,
    answer: DeviceList(
      owner: 'someone@example.com',
      invited: const <String>['someone@example.com'],
      emailEnabled: email,
      devices: <SignedInDevice>[
        device(kPhone, current: mine),
        for (final String label in others)
          device(label, current: false, expires: expires),
      ],
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        identityServiceProvider.overrideWithValue(companion),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: const AccountScreen(),
      ),
    ),
  );
  // Bounded pumps: the screen shows a progress bar while it looks, and that
  // animation never ends, so pumpAndSettle would wait for a last frame that
  // never comes.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return companion;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a token of this phone\u2019s own is not offered a code', (
    WidgetTester tester,
  ) async {
    await pumpAccount(tester, token: kOwn, mine: true);

    expect(find.text("this phone's own"), findsOneWidget);
    expect(find.text('the server wide one'), findsNothing);
    expect(find.text('Email me a code'), findsNothing);
    expect(find.text('Sign this phone out'), findsOneWidget);
    expect(find.textContaining('holds a token of its own now'), findsOneWidget);
  });

  testWidgets('the server wide token is offered a code instead', (
    WidgetTester tester,
  ) async {
    await pumpAccount(tester, token: kRoot, mine: false);

    expect(find.text('the server wide one'), findsOneWidget);
    expect(find.text("this phone's own"), findsNothing);
    expect(find.text('Email me a code'), findsOneWidget);
    expect(
      find.textContaining('Signing in replaces it on this phone'),
      findsOneWidget,
    );
  });

  testWidgets('a phone with no token at all says so and still offers a code', (
    WidgetTester tester,
  ) async {
    await pumpAccount(tester, token: '', mine: false);

    expect(find.text('none on this phone'), findsOneWidget);
    expect(find.text('Email me a code'), findsOneWidget);
    // The two address buttons need a token: without one there is nothing on
    // this phone for the companion to recognise.
    final OutlinedButton vault = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Vault link'),
    );
    expect(vault.onPressed, isNull);
  });

  testWidgets('the vault link is mailed once there is a token', (
    WidgetTester tester,
  ) async {
    final FakeCompanion companion = await pumpAccount(
      tester,
      token: kOwn,
      mine: true,
    );

    await tester.ensureVisible(find.text('Vault link'));
    await tester.pump();
    await tester.tap(find.text('Vault link'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(companion.mailed, <String>['vault']);
    expect(find.textContaining('It opens the vault page'), findsOneWidget);
  });

  testWidgets('another device can be revoked, and the list says so', (
    WidgetTester tester,
  ) async {
    final FakeCompanion companion = await pumpAccount(
      tester,
      token: kOwn,
      mine: true,
      others: <String>['vault-link'],
      // Six days and an hour, so the sentence is stable whichever way the
      // clock moves between building the list and drawing it.
      expires: DateTime.now().add(const Duration(days: 6, hours: 1)),
    );

    expect(find.textContaining('vault-link'), findsOneWidget);
    // A link that lasts a week says so; reading a future date with the
    // past-facing formatter said "expires just now".
    expect(find.textContaining('expires in 6 d'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Revoke').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Revoke').first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(companion.revoked, <String>['vault-link']);
    expect(
      find.textContaining('can no longer write to your server'),
      findsOneWidget,
    );
    // This phone is not a row that can be revoked from here: the way out of it
    // is signing out, which is a different button.
    expect(find.byTooltip('Revoke'), findsNothing);
  });

  testWidgets('with no mail key on the companion, nothing is offered', (
    WidgetTester tester,
  ) async {
    await pumpAccount(tester, token: kOwn, mine: true, email: false);

    expect(find.textContaining('Email is switched off'), findsOneWidget);

    final OutlinedButton vault = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Vault link'),
    );
    expect(vault.onPressed, isNull);
  });

  testWidgets('a companion that cannot be reached says why', (
    WidgetTester tester,
  ) async {
    // A surface tall enough that the whole screen is built: a ListView only
    // builds what fits, and the parts of this one worth asserting on - the email
    // buttons and the closing sentence - are the parts furthest down.
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettings settings = await AppSettings.load(
      secrets: MemorySecretStore(),
    );
    settings.backupEndpoint = 'https://example.com/arcanum';
    settings.backupToken = kOwn;
    final IdentityService companion = _Unreachable(settings: settings);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWithValue(settings),
          identityServiceProvider.overrideWithValue(companion),
        ],
        child: MaterialApp(
          theme: AppTheme.build(dark: true),
          home: const AccountScreen(),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('not accepted'), findsOneWidget);
    expect(find.textContaining('the server did not answer'), findsOneWidget);
  });
}

/// A companion that never answers at all.
class _Unreachable extends IdentityService {
  _Unreachable({required super.settings});

  @override
  Future<DeviceList> look() async =>
      throw const CompanionException('the server did not answer');
}
