import 'package:arcanum/core/utils/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fresh settings object over a given stored state.
Future<AppSettings> settingsWith(Map<String, Object> stored) async {
  SharedPreferences.setMockInitialValues(stored);
  return AppSettings.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('history endpoints', () {
    test('default both games to the hosted companion over TLS', () async {
      final AppSettings settings = await settingsWith(<String, Object>{});

      expect(settings.historyEndpoint, AppSettings.defaultHistoryEndpoint);
      expect(
        settings.pokemonHistoryEndpoint,
        AppSettings.defaultPokemonHistoryEndpoint,
      );
      // One companion holds both databases, so both games ask the same address.
      expect(
        AppSettings.defaultPokemonHistoryEndpoint,
        AppSettings.defaultHistoryEndpoint,
      );
      // Cleartext on a public address was the reason the app needed a
      // cleartext exception at all; the default must not reintroduce it.
      expect(settings.historyEndpoint.startsWith('https://'), isTrue);
    });

    test('moves an install off the retired tailnet default', () async {
      // Builds before 1.2.0 shipped a private Tailscale address as the default.
      // An install that never touched the field is on it and cannot reach a
      // desktop that is asleep, so it is migrated rather than stranded.
      final AppSettings settings = await settingsWith(<String, Object>{
        'history_endpoint': AppSettings.legacyHistoryEndpoint,
      });

      expect(settings.historyEndpoint, AppSettings.defaultHistoryEndpoint);
    });

    test('never rewrites an endpoint the collector typed', () async {
      final AppSettings settings = await settingsWith(<String, Object>{
        'history_endpoint': 'http://192.168.1.9:8787',
        'pokemon_history_endpoint': 'https://cards.example.net',
      });

      expect(settings.historyEndpoint, 'http://192.168.1.9:8787');
      expect(settings.pokemonHistoryEndpoint, 'https://cards.example.net');
    });

    test('treats a blank or padded value as unset', () async {
      final AppSettings settings = await settingsWith(<String, Object>{
        'history_endpoint': '   ',
        'pokemon_history_endpoint': '',
      });

      expect(settings.historyEndpoint, AppSettings.defaultHistoryEndpoint);
      expect(
        settings.pokemonHistoryEndpoint,
        AppSettings.defaultPokemonHistoryEndpoint,
      );
    });

    test('trims what is stored, so a pasted URL still resolves', () async {
      final AppSettings settings = await settingsWith(<String, Object>{});
      settings.historyEndpoint = '  https://example.net/arcanum  ';

      expect(settings.historyEndpoint, 'https://example.net/arcanum');
    });
  });
}
