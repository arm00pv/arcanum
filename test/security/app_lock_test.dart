import 'package:arcanum/data/security/app_lock.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldRelock', () {
    final now = DateTime(2026, 9, 14, 12);

    test('an app that has never been backgrounded is not re-locked', () {
      expect(shouldRelock(pausedAt: null, now: now), isFalse);
    });

    test('a glance at another app does not lock the vault', () {
      expect(
        shouldRelock(
          pausedAt: now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        isFalse,
      );
    });

    test('exactly the grace period is still inside it', () {
      expect(
        shouldRelock(pausedAt: now.subtract(kLockGrace), now: now),
        isFalse,
      );
    });

    test('a minute and a half away locks it again', () {
      expect(
        shouldRelock(
          pausedAt: now.subtract(const Duration(seconds: 91)),
          now: now,
        ),
        isTrue,
      );
    });

    test('the grace period can be set by the caller', () {
      expect(
        shouldRelock(
          pausedAt: now.subtract(const Duration(seconds: 5)),
          now: now,
          grace: const Duration(seconds: 2),
        ),
        isTrue,
      );
    });
  });

  group('OpenDeviceAuth', () {
    test('reports that nothing is available rather than pretending', () async {
      const auth = OpenDeviceAuth();
      expect(await auth.isAvailable, isFalse);
      expect(await auth.authenticate('anything'), isFalse);
      expect(await auth.describe(), 'nothing');
    });
  });

  group('MemorySecretStore', () {
    test('keeps, replaces and forgets a value', () async {
      final store = MemorySecretStore();
      expect(await store.read('k'), isNull);
      await store.write('k', 'v1');
      expect(await store.read('k'), 'v1');
      await store.write('k', 'v2');
      expect(await store.read('k'), 'v2');
      await store.delete('k');
      expect(await store.read('k'), isNull);
    });

    test(
      'can refuse every write, standing in for a stubborn keystore',
      () async {
        final store = MemorySecretStore()..refuseWrites = true;
        await expectLater(store.write('k', 'v'), throwsA(isA<StateError>()));
        expect(store.values, isEmpty);
      },
    );
  });
}
