import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings over a given stored state and a given keystore.
Future<AppSettings> settingsWith(
  Map<String, Object> stored, {
  SecretStore? secrets,
}) async {
  SharedPreferences.setMockInitialValues(stored);
  return AppSettings.load(secrets: secrets ?? MemorySecretStore());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('moving credentials into the keystore', () {
    test(
      'a token left in the preferences is moved and deleted from them',
      () async {
        final store = MemorySecretStore();
        final settings = await settingsWith(<String, Object>{
          'backup_token': 'old-token',
        }, secrets: store);

        expect(settings.backupToken, 'old-token');
        expect(store.values['backup_token'], 'old-token');
        // The plain copy is what the move exists to remove; leaving it behind
        // would leave the secret in the file it was moved out of.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backup_token'), isNull);
      },
    );

    test('the price-history key is moved the same way', () async {
      final store = MemorySecretStore();
      final settings = await settingsWith(<String, Object>{
        'justtcg_key': 'justtcg-abc',
      }, secrets: store);

      expect(settings.justTcgKey, 'justtcg-abc');
      expect(store.values['justtcg_key'], 'justtcg-abc');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('justtcg_key'), isNull);
    });

    test('a value already in the keystore wins over the old copy', () async {
      final store = MemorySecretStore(<String, String>{
        'backup_token': 'from-the-keystore',
      });
      final settings = await settingsWith(<String, Object>{
        'backup_token': 'stale-in-the-preferences',
      }, secrets: store);

      expect(settings.backupToken, 'from-the-keystore');
    });

    test(
      'a new token is written to the keystore, not the preferences',
      () async {
        final store = MemorySecretStore();
        final settings = await settingsWith(<String, Object>{}, secrets: store);

        settings.backupToken = '  fresh-token  ';
        await pumpEventQueue();

        expect(settings.backupToken, 'fresh-token');
        expect(store.values['backup_token'], 'fresh-token');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backup_token'), isNull);
      },
    );

    test('clearing a token clears the keystore entry', () async {
      final store = MemorySecretStore(<String, String>{'backup_token': 't'});
      final settings = await settingsWith(<String, Object>{}, secrets: store);
      expect(settings.backupToken, 't');

      settings.backupToken = '';
      await pumpEventQueue();

      expect(settings.backupToken, '');
      expect(store.values.containsKey('backup_token'), isFalse);
    });

    test('a keystore that refuses is not fatal, and is reported', () async {
      final store = MemorySecretStore()..refuseWrites = true;
      final settings = await settingsWith(<String, Object>{
        'backup_token': 'kept-anyway',
      }, secrets: store);

      // Reading failed too, so the value stays where it was found...
      expect(settings.backupToken, 'kept-anyway');
      expect(settings.secretStorageDegraded, isTrue);
    });

    test(
      'a refused write keeps the token in the preferences and says so',
      () async {
        final store = MemorySecretStore();
        final settings = await settingsWith(<String, Object>{}, secrets: store);
        store.refuseWrites = true;

        settings.backupToken = 'still-works';
        await pumpEventQueue();

        expect(settings.backupToken, 'still-works');
        expect(settings.secretStorageDegraded, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backup_token'), 'still-works');
      },
    );

    test('an install with no credentials anywhere is not degraded', () async {
      final settings = await settingsWith(<String, Object>{});
      expect(settings.backupToken, '');
      expect(settings.justTcgKey, '');
      expect(settings.secretStorageDegraded, isFalse);
    });
  });

  group('the lock preference', () {
    test('is off until it is asked for', () async {
      final settings = await settingsWith(<String, Object>{});
      expect(settings.lockEnabled, isFalse);
    });

    test('survives a reload', () async {
      final settings = await settingsWith(<String, Object>{});
      settings.lockEnabled = true;
      await pumpEventQueue();

      final again = await settingsWith(<String, Object>{'lock_enabled': true});
      expect(again.lockEnabled, isTrue);
    });
  });
}
