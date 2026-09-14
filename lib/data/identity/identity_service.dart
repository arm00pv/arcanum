import 'package:dio/dio.dart';

import 'package:arcanum/core/utils/app_settings.dart';

/// A moment the companion sent, which is always unix seconds.
///
/// One way of reading it, in one place: the two dates this service parses are
/// the same kind of number, and a count of seconds handed to a date parser is
/// read as a year - which is how a code that lasts ten minutes came to expire
/// in the year 178944.
DateTime? atSeconds(Object? value) {
  final int seconds = (value as num?)?.toInt() ?? 0;
  if (seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).toLocal();
}

/// What the companion said when a sign-in code was asked for.
///
/// The two fields that matter are not the same thing. [sent] says a code left
/// the server; [error] is why one did not, in the companion's own words - and
/// it is only filled in for a caller who already holds a token, because an
/// address that is not invited must not be able to learn that from outside.
class CodeSent {
  /// Describes one answer to a sign-in request.
  const CodeSent({
    required this.sent,
    this.expires,
    this.error,
    this.retryIn = 0,
    this.invited = const <String>[],
  });

  /// Whether a code was actually mailed.
  final bool sent;

  /// When it stops working.
  final DateTime? expires;

  /// Why nothing was sent, when the companion was willing to say.
  final String? error;

  /// Seconds to wait before asking again, when the rate limit refused.
  final int retryIn;

  /// The addresses this server will send to, when it said.
  final List<String> invited;

  /// Reads an answer.
  static CodeSent fromJson(Object? raw) {
    if (raw is! Map) return const CodeSent(sent: false);
    final String why = (raw['error'] ?? '').toString().trim();
    return CodeSent(
      sent: raw['sent'] == true,
      expires: atSeconds(raw['expires']),
      error: why.isEmpty ? null : why,
      retryIn: (raw['retry_in'] as num?)?.toInt() ?? 0,
      invited: <String>[
        for (final Object? address
            in (raw['invited'] as List<Object?>?) ?? const <Object?>[])
          address.toString(),
      ],
    );
  }
}

/// One device the companion will accept a token from.
class SignedInDevice {
  /// Describes one device.
  const SignedInDevice({
    required this.label,
    required this.created,
    required this.lastSeen,
    required this.expires,
    required this.current,
  });

  /// What the device called itself, which is the phone's own name.
  final String label;

  /// When it was signed in.
  final DateTime? created;

  /// When it last used its token.
  final DateTime? lastSeen;

  /// When it stops working, or null when it does not.
  final DateTime? expires;

  /// Whether this is the token this phone is holding.
  final bool current;

  /// Reads one device row.
  static SignedInDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String label = (raw['label'] ?? '').toString();
    if (label.isEmpty) return null;
    return SignedInDevice(
      label: label,
      created: atSeconds(raw['created']),
      lastSeen: atSeconds(raw['last_seen']),
      expires: atSeconds(raw['expires']),
      current: raw['current'] == true,
    );
  }

  /// Whether this device's token has run out, as of [now].
  bool hasExpired(DateTime now) => expires != null && expires!.isBefore(now);
}

/// The companion's view of who may use it.
class DeviceList {
  /// Describes one answer from the device route.
  const DeviceList({
    required this.owner,
    required this.invited,
    required this.emailEnabled,
    required this.devices,
  });

  /// The address that owns the server, or empty when it has not been set.
  final String owner;

  /// Every other address allowed in.
  final List<String> invited;

  /// Whether the companion has a mail key, so codes can be sent at all.
  final bool emailEnabled;

  /// The devices holding a token.
  final List<SignedInDevice> devices;

  /// Reads the answer.
  static DeviceList fromJson(Object? raw) {
    if (raw is! Map) {
      return const DeviceList(
        owner: '',
        invited: <String>[],
        emailEnabled: false,
        devices: <SignedInDevice>[],
      );
    }
    return DeviceList(
      owner: (raw['owner'] ?? '').toString(),
      invited: <String>[
        for (final Object? address
            in (raw['invited'] as List<Object?>?) ?? const <Object?>[])
          address.toString(),
      ],
      emailEnabled: raw['email'] == true,
      devices: <SignedInDevice>[
        for (final Object? row
            in (raw['devices'] as List<Object?>?) ?? const <Object?>[])
          if (SignedInDevice.fromJson(row) case final SignedInDevice device)
            device,
      ],
    );
  }

  /// Whether this server has been given an owner at all.
  bool get hasOwner => owner.isNotEmpty;
}

/// A refusal from the companion, carrying the sentence it wrote.
///
/// The companion's refusals are written for the collector - that an address is
/// not invited, that Resend will only send to its own address - and replacing
/// them with an HTTP status would throw away the only part of the answer that
/// says what to do next.
class CompanionException implements Exception {
  /// Creates a refusal.
  const CompanionException(
    this.message, {
    this.status = 0,
    this.invited = const <String>[],
  });

  /// What the companion said.
  final String message;

  /// The status it said it with, or 0 when it never answered.
  final int status;

  /// The addresses it will send to, when the refusal named them.
  final List<String> invited;

  @override
  String toString() => message;
}

/// Signing in to the collector's own companion without a password.
///
/// There is no account and no password: the server knows one collection, so the
/// question is only ever whether this is the person who owns that server. The
/// answer is a six-digit code mailed to an address the server already holds,
/// traded once for a token for this phone - which is then the same token every
/// other request uses, because a second kind of secret would be a second thing
/// to lose.
class IdentityService {
  /// Creates the service.
  IdentityService({required AppSettings settings, Dio? dio})
    : _settings = settings,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
            ),
          );

  final AppSettings _settings;
  final Dio _dio;

  /// True when the collector has named a companion.
  bool get isConfigured => _settings.backupEndpoint.trim().isNotEmpty;

  String get _root => _settings.backupEndpoint.replaceAll(RegExp(r'/+$'), '');

  /// The stored token, when there is one. An empty header is not sent: the
  /// companion reads that as no credential rather than as a failed one.
  Map<String, String> get _auth {
    final String token = _settings.backupToken.trim();
    return token.isEmpty
        ? const <String, String>{}
        : <String, String>{'X-Arcanum-Token': token};
  }

  /// Asks the companion to mail a sign-in code to [email].
  Future<CodeSent> startCode(String email) async {
    try {
      final res = await _dio.post<dynamic>(
        '$_root/v1/auth/start',
        data: <String, String>{'email': email.trim()},
        options: Options(headers: _auth),
      );
      return CodeSent.fromJson(res.data);
    } on DioException catch (error) {
      throw _refusal(error, 'The companion could not be asked for a code');
    }
  }

  /// Trades [code] for this phone's own token, and returns it.
  Future<String> verify({
    required String email,
    required String code,
    required String device,
  }) async {
    final Object? data;
    try {
      final res = await _dio.post<dynamic>(
        '$_root/v1/auth/verify',
        data: <String, String>{
          'email': email.trim(),
          'code': code.trim(),
          'device': device.trim(),
        },
        options: Options(headers: _auth),
      );
      data = res.data;
    } on DioException catch (error) {
      throw _refusal(error, 'That code was not accepted');
    }
    final String token = data is Map
        ? (data['token'] ?? '').toString().trim()
        : '';
    if (token.isEmpty) {
      throw const CompanionException(
        'The companion accepted the code but sent no token back.',
      );
    }
    return token;
  }

  /// Everything the companion will say about who may use it.
  Future<DeviceList> look() async {
    try {
      final res = await _dio.get<dynamic>(
        '$_root/v1/auth/devices',
        options: Options(headers: _auth),
      );
      return DeviceList.fromJson(res.data);
    } on DioException catch (error) {
      throw _refusal(error, 'The companion did not list its devices');
    }
  }

  /// Takes one device's token away.
  Future<bool> revoke(String label) async {
    try {
      final res = await _dio.post<dynamic>(
        '$_root/v1/auth/revoke',
        data: <String, String>{'device': label},
        options: Options(headers: _auth),
      );
      final Object? data = res.data;
      return data is Map && data['removed'] == true;
    } on DioException catch (error) {
      throw _refusal(error, 'That device could not be revoked');
    }
  }

  /// Has the companion mail a link that opens the vault page in a browser.
  Future<void> emailVaultLink({String to = ''}) =>
      _email('/v1/email/vault', to, 'The vault link could not be sent');

  /// Has the companion mail the newest archive as an attachment.
  Future<void> emailBackup({String to = ''}) =>
      _email('/v1/email/backup', to, 'The backup could not be sent');

  Future<void> _email(String path, String to, String fallback) async {
    try {
      await _dio.post<dynamic>(
        '$_root$path',
        data: to.trim().isEmpty
            ? const <String, String>{}
            : <String, String>{'to': to.trim()},
        options: Options(headers: _auth),
      );
    } on DioException catch (error) {
      throw _refusal(error, fallback);
    }
  }

  /// Turns a Dio failure into the companion's own sentence, or an honest one.
  CompanionException _refusal(DioException error, String fallback) {
    final Response<dynamic>? res = error.response;
    final Object? data = res?.data;
    if (data is Map) {
      final String message = (data['error'] ?? '').toString().trim();
      if (message.isNotEmpty) {
        return CompanionException(
          message,
          status: res?.statusCode ?? 0,
          invited: <String>[
            for (final Object? address
                in (data['invited'] as List<Object?>?) ?? const <Object?>[])
              address.toString(),
          ],
        );
      }
    }
    if (res == null) {
      final String detail = (error.message ?? '').trim();
      return CompanionException(
        detail.isEmpty
            ? '$fallback: the server could not be reached.'
            : '$fallback: the server could not be reached ($detail).',
      );
    }
    return CompanionException(
      '$fallback (HTTP ${res.statusCode}).',
      status: res.statusCode ?? 0,
    );
  }
}
