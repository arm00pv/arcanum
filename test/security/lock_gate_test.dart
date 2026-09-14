// The lock's own behaviour, without a fingerprint reader.
//
//   flutter test test/security/lock_gate_test.dart
//
// The prompt itself belongs to the phone and is verified on the device. What
// this file pins is everything around it: that the cover is over the app rather
// than beside it, that a refusal keeps it there, and that the copy does not
// promise a password Arcanum does not have.

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/security/app_lock.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/features/security/lock_gate.dart';
import 'package:arcanum/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone that answers however the test tells it to.
class FakeAuth implements DeviceAuth {
  FakeAuth({this.answers = true, this.method = 'fingerprint'});

  /// What the next prompt returns.
  bool answers;

  /// What the device says it will ask for.
  String method;

  /// How many prompts have been shown.
  int asks = 0;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<String> describe() async => method;

  @override
  Future<bool> authenticate(String reason) async {
    asks++;
    return answers;
  }
}

/// Settings with the lock either on or off.
Future<AppSettings> settingsWithLock(bool locked) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'lock_enabled': locked,
  });
  return AppSettings.load(secrets: MemorySecretStore());
}

/// Pumps the app with the lock wrapped around the navigator, exactly as
/// main.dart's widget tree does it.
Future<void> pumpGate(
  WidgetTester tester, {
  required AppSettings settings,
  required DeviceAuth auth,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        deviceAuthProvider.overrideWithValue(auth),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (BuildContext context, Widget? child) =>
            LockGate(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: Text('the collection')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an app with the lock off is not covered', (tester) async {
    final auth = FakeAuth();
    await pumpGate(tester, settings: await settingsWithLock(false), auth: auth);

    expect(find.text('the collection'), findsOneWidget);
    expect(find.text('Arcanum is locked'), findsNothing);
    expect(auth.asks, 0);
  });

  testWidgets('a locked app asks the phone, and opens when it agrees', (
    tester,
  ) async {
    final auth = FakeAuth(answers: true);
    await pumpGate(tester, settings: await settingsWithLock(true), auth: auth);

    expect(auth.asks, 1);
    expect(find.text('Arcanum is locked'), findsNothing);
    expect(find.text('the collection'), findsOneWidget);
  });

  testWidgets('a refusal keeps the cover on and says what happened', (
    tester,
  ) async {
    final auth = FakeAuth(answers: false);
    await pumpGate(tester, settings: await settingsWithLock(true), auth: auth);

    expect(find.text('Arcanum is locked'), findsOneWidget);
    expect(find.text('The phone did not recognise you.'), findsOneWidget);
    // The collection is not merely behind the cover: it is not built at all.
    expect(find.text('the collection'), findsNothing);

    // And the button asks again rather than giving up.
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(auth.asks, 2);
  });

  testWidgets('the cover names whatever the phone will actually ask for', (
    tester,
  ) async {
    final auth = FakeAuth(answers: false, method: 'face');
    await pumpGate(tester, settings: await settingsWithLock(true), auth: auth);

    expect(
      find.text('Unlock with your face to see the collection.'),
      findsOneWidget,
    );
  });

  testWidgets('the cover never promises a password Arcanum does not have', (
    tester,
  ) async {
    await pumpGate(
      tester,
      settings: await settingsWithLock(true),
      auth: FakeAuth(answers: false),
    );

    final Finder copy = find.textContaining('no account and no password');
    expect(copy, findsOneWidget);
  });

  testWidgets('a glance at another app does not bring the cover back', (
    tester,
  ) async {
    final auth = FakeAuth(answers: true);
    await pumpGate(tester, settings: await settingsWithLock(true), auth: auth);
    expect(find.text('the collection'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    // Back well inside the grace period: no new prompt, still open.
    expect(auth.asks, 1);
    expect(find.text('the collection'), findsOneWidget);
  });

  testWidgets('an app with the lock off does not lock on a resume either', (
    tester,
  ) async {
    final auth = FakeAuth();
    await pumpGate(tester, settings: await settingsWithLock(false), auth: auth);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(auth.asks, 0);
    expect(find.text('Arcanum is locked'), findsNothing);
  });
}
