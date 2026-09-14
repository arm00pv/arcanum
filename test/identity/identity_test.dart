// Signing in without a password: the code, the token, and the refusals.
//
//   flutter test test/identity/identity_test.dart
//
// The companion's refusals are written for the person reading them - that an
// address is not invited, that Resend will only mail its own address - so most
// of what this file pins down is that those sentences survive the trip and are
// not flattened into an HTTP status on the way.

import 'dart:convert';
import 'dart:typed_data';

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/identity/identity_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A companion that answers whatever the test tells it to, and remembers.
class _FakeCompanion implements HttpClientAdapter {
  _FakeCompanion(this._answer);

  /// The status and body to answer with, for one request.
  final (int, Object?) Function(Uri uri, String method) _answer;

  /// Every request as "METHOD /path".
  final List<String> requests = <String>[];

  /// What each request carried in its body.
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  /// What each request carried in its headers.
  final List<Map<String, dynamic>> headers = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    headers.add(Map<String, dynamic>.from(options.headers));
    final chunks = <int>[];
    if (requestStream != null) {
      await for (final Uint8List chunk in requestStream) {
        chunks.addAll(chunk);
      }
    }
    final String text = chunks.isEmpty ? '' : utf8.decode(chunks);
    bodies.add(
      text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
    final (int status, Object? payload) = _answer(options.uri, options.method);
    return ResponseBody.fromString(
      payload is String ? payload : jsonEncode(payload),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A service pointed at the fake, with the settings a phone would have.
Future<(IdentityService, _FakeCompanion, AppSettings)> wired(
  (int, Object?) Function(Uri uri, String method) answer, {
  String token = '',
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'backup_endpoint': 'https://example.com/arcanum/',
    'backup_token': token,
  });
  final settings = await AppSettings.load();
  final fake = _FakeCompanion(answer);
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)))
    ..httpClientAdapter = fake;
  return (IdentityService(settings: settings, dio: dio), fake, settings);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asks the companion for a code and reads what it said', () async {
    final (service, fake, _) = await wired(
      (Uri uri, String method) => (
        200,
        <String, Object?>{
          'ok': true,
          'sent': true,
          'to': 'owner@example.com',
          'expires': 1789396378,
        },
      ),
    );

    final CodeSent sent = await service.startCode('owner@example.com');

    expect(fake.requests, <String>['POST /arcanum/v1/auth/start']);
    expect(fake.bodies.single['email'], 'owner@example.com');
    expect(sent.sent, isTrue);
    expect(sent.error, isNull);
    expect(
      sent.expires,
      DateTime.fromMillisecondsSinceEpoch(1789396378 * 1000),
    );
  });

  test('keeps the companion explanation when no code was sent', () async {
    final (service, _, _) = await wired(
      (Uri uri, String method) =>
          (200, <String, Object?>{'ok': true, 'sent': false, 'retry_in': 42}),
    );

    final CodeSent sent = await service.startCode('owner@example.com');

    expect(sent.sent, isFalse);
    expect(sent.retryIn, 42);
  });

  test(
    'says which addresses are invited when the companion named them',
    () async {
      final (service, _, _) = await wired(
        (Uri uri, String method) => (
          200,
          <String, Object?>{
            'ok': true,
            'sent': false,
            'error': 'that address is not invited to this server',
            'invited': <String>['owner@example.com'],
          },
        ),
      );

      final CodeSent sent = await service.startCode('stranger@example.com');

      expect(sent.error, 'that address is not invited to this server');
      expect(sent.invited, <String>['owner@example.com']);
    },
  );

  test('sends no token header at all when the phone has no token', () async {
    final (service, fake, _) = await wired(
      (Uri uri, String method) =>
          (200, <String, Object?>{'ok': true, 'sent': true}),
    );

    await service.startCode('owner@example.com');

    expect(fake.headers.single.containsKey('X-Arcanum-Token'), isFalse);
  });

  test(
    'sends the stored token, so the companion can answer honestly',
    () async {
      final (service, fake, _) = await wired(
        (Uri uri, String method) =>
            (200, <String, Object?>{'ok': true, 'sent': true}),
        token: 'root-token',
      );

      await service.startCode('owner@example.com');

      expect(fake.headers.single['X-Arcanum-Token'], 'root-token');
    },
  );

  test('trades the code for a token, naming the phone it is for', () async {
    final (service, fake, _) = await wired(
      (Uri uri, String method) => (
        200,
        <String, Object?>{
          'ok': true,
          'token': 'device-token',
          'device': 'arcanum-hma1',
        },
      ),
    );

    final String token = await service.verify(
      email: 'owner@example.com',
      code: ' 123456 ',
      device: 'arcanum-hma1',
    );

    expect(token, 'device-token');
    expect(fake.requests, <String>['POST /arcanum/v1/auth/verify']);
    expect(fake.bodies.single, <String, dynamic>{
      'email': 'owner@example.com',
      'code': '123456',
      'device': 'arcanum-hma1',
    });
  });

  test('carries the refusal in the companion own words', () async {
    final (service, _, _) = await wired(
      (Uri uri, String method) => (
        401,
        <String, Object?>{
          'ok': false,
          'error': 'that code has expired - ask for a new one',
        },
      ),
    );

    await expectLater(
      service.verify(
        email: 'owner@example.com',
        code: '000000',
        device: 'phone',
      ),
      throwsA(
        isA<CompanionException>()
            .having(
              (CompanionException e) => e.message,
              'message',
              'that code has expired - ask for a new one',
            )
            .having((CompanionException e) => e.status, 'status', 401),
      ),
    );
  });

  test('refuses a token the companion forgot to send', () async {
    final (service, _, _) = await wired(
      (Uri uri, String method) => (200, <String, Object?>{'ok': true}),
    );

    await expectLater(
      service.verify(email: 'o@example.com', code: '123456', device: 'phone'),
      throwsA(isA<CompanionException>()),
    );
  });

  test('reads the device list, with this phone marked', () async {
    final (service, fake, _) = await wired(
      (Uri uri, String method) => (
        200,
        <String, Object?>{
          'ok': true,
          'owner': 'owner@example.com',
          'invited': <String>['friend@example.com'],
          'email': true,
          'devices': <Object?>[
            <String, Object?>{
              'label': 'arcanum-hma1',
              'created': 1789390000,
              'last_seen': 1789396000,
              'expires': 0,
              'current': true,
            },
            <String, Object?>{
              'label': 'vault-link',
              'created': 1789390000,
              'last_seen': 1789390000,
              'expires': 1790000000,
              'current': false,
            },
          ],
        },
      ),
      token: 'device-token',
    );

    final DeviceList list = await service.look();

    expect(fake.requests, <String>['GET /arcanum/v1/auth/devices']);
    expect(list.owner, 'owner@example.com');
    expect(list.invited, <String>['friend@example.com']);
    expect(list.emailEnabled, isTrue);
    expect(list.devices, hasLength(2));
    expect(list.devices.first.label, 'arcanum-hma1');
    expect(list.devices.first.current, isTrue);
    expect(list.devices.first.created, isNotNull);
    expect(
      list.devices.first.created!.isUtc,
      isFalse,
      reason: 'a time the collector reads is a local time',
    );
    expect(list.devices.last.current, isFalse);
    expect(list.devices.last.expires, isNotNull);
  });

  test('revokes a device by name', () async {
    final (service, fake, _) = await wired(
      (Uri uri, String method) =>
          (200, <String, Object?>{'ok': true, 'removed': true}),
      token: 'device-token',
    );

    final bool removed = await service.revoke('vault-link');

    expect(removed, isTrue);
    expect(fake.requests, <String>['POST /arcanum/v1/auth/revoke']);
    expect(fake.bodies.single['device'], 'vault-link');
  });

  test('emails the vault link, and the address when one was given', () async {
    final (service, fake, _) = await wired(
      (Uri uri, String method) =>
          (200, <String, Object?>{'ok': true, 'sent': true}),
      token: 'device-token',
    );

    await service.emailVaultLink();
    await service.emailBackup(to: 'friend@example.com');

    expect(fake.requests, <String>[
      'POST /arcanum/v1/email/vault',
      'POST /arcanum/v1/email/backup',
    ]);
    expect(fake.bodies.first, isEmpty);
    expect(fake.bodies.last['to'], 'friend@example.com');
  });

  test('passes on what Resend said when it refused', () async {
    final (service, _, _) = await wired(
      (Uri uri, String method) => (
        502,
        <String, Object?>{
          'ok': false,
          'error':
              'You can only send testing emails to your own email address '
              '(info@example.com).',
        },
      ),
      token: 'device-token',
    );

    await expectLater(
      service.emailBackup(),
      throwsA(
        isA<CompanionException>().having(
          (CompanionException e) => e.message,
          'message',
          contains('your own email address'),
        ),
      ),
    );
  });

  test(
    'says the server could not be reached rather than showing a status',
    () async {
      final (service, _, _) = await wired(
        (Uri uri, String method) => throw const _Unreachable(),
      );

      await expectLater(
        service.look(),
        throwsA(
          isA<CompanionException>().having(
            (CompanionException e) => e.message,
            'message',
            contains('could not be reached'),
          ),
        ),
      );
    },
  );

  test('knows when a mailed link has run out', () {
    const SignedInDevice link = SignedInDevice(
      label: 'vault-link',
      created: null,
      lastSeen: null,
      expires: null,
      current: false,
    );
    expect(link.hasExpired(DateTime.now()), isFalse);
    expect(
      link.hasExpired(DateTime.now()),
      isFalse,
      reason: 'a device with no expiry is a phone, not a link',
    );
  });
}

/// The transport failing, which Dio reports as a DioException with no response.
class _Unreachable implements Exception {
  const _Unreachable();
}
