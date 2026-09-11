import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/data/update/update_service.dart';

/// Serves one canned GitHub answer without touching the network.
class _FakeGitHub implements HttpClientAdapter {
  _FakeGitHub(this.status, this.body);

  final int status;
  final String body;

  /// Every URI asked for, so a test can prove which repository was queried.
  final List<Uri> requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(
      body,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

UpdateService serviceFor(int status, String body, {String current = '1.0.0'}) {
  final dio = Dio();
  dio.httpClientAdapter = _FakeGitHub(status, body);
  return UpdateService(
    dio: dio,
    currentVersion: current,
    slug: 'someone/arcanum',
  );
}

String releaseJson(String tag) =>
    '{"tag_name":"$tag","name":"Arcanum $tag","body":"Notes here.",'
    '"html_url":"https://github.com/someone/arcanum/releases/tag/$tag",'
    '"published_at":"2026-09-01T10:00:00Z"}';

void main() {
  group('compareVersions', () {
    test('orders by number, not by text', () {
      // The case a string comparison gets backwards.
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('1.9.0', '1.10.0'), lessThan(0));
      expect(compareVersions('2.0.0', '10.0.0'), lessThan(0));
    });

    test('treats a missing segment as zero', () {
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2.0', '1.2'), 0);
      expect(compareVersions('1', '1.0.1'), lessThan(0));
    });

    test('ignores a leading v on either side', () {
      expect(compareVersions('v1.2.0', '1.2.0'), 0);
      expect(compareVersions('1.2.0', 'v1.2.0'), 0);
      expect(compareVersions('v1.3.0', 'v1.2.0'), greaterThan(0));
    });

    test('sorts a pre-release before the release it leads to', () {
      expect(compareVersions('1.0.0-beta', '1.0.0'), lessThan(0));
      expect(compareVersions('1.0.0', '1.0.0-beta'), greaterThan(0));
      expect(compareVersions('1.0.0-beta', '1.0.0-alpha'), greaterThan(0));
    });

    test('reports equality for the same version', () {
      expect(compareVersions('1.4.2', '1.4.2'), 0);
    });
  });

  group('stripVersionPrefix', () {
    test('removes a v that leads into a number', () {
      expect(stripVersionPrefix('v1.2.0'), '1.2.0');
      expect(stripVersionPrefix('V2.0'), '2.0');
      expect(stripVersionPrefix('  1.2.0  '), '1.2.0');
    });

    test('leaves a tag that merely starts with a v alone', () {
      expect(stripVersionPrefix('vortex'), 'vortex');
      expect(stripVersionPrefix('v'), 'v');
    });
  });

  group('ReleaseInfo', () {
    test('reads a release, normalising the tag', () {
      final info = ReleaseInfo.fromJson(<String, Object?>{
        'tag_name': 'v1.3.0',
        'name': 'Arcanum 1.3.0',
        'body': 'Fixes.',
        'html_url': 'https://example.test/r',
        'published_at': '2026-09-01T10:00:00Z',
      });

      expect(info.version, '1.3.0');
      expect(info.title, 'Arcanum 1.3.0');
      expect(info.notes, 'Fixes.');
      expect(info.publishedAt, DateTime.utc(2026, 9, 1, 10));
    });

    test('falls back to the tag when the release has no title', () {
      final info = ReleaseInfo.fromJson(<String, Object?>{'tag_name': 'v1.0.0'});
      expect(info.title, 'v1.0.0');
      expect(info.url, '');
      expect(info.notes, '');
      expect(info.publishedAt, isNull);
    });
  });

  group('UpdateService.check', () {
    test('reports a newer release and where to get it', () async {
      final service = serviceFor(200, releaseJson('v1.4.0'), current: '1.3.0');

      final result = await service.check();

      expect(result.status, UpdateStatus.updateAvailable);
      expect(result.release!.version, '1.4.0');
      expect(result.release!.url, contains('/releases/tag/v1.4.0'));
    });

    test('reports being current when the tag is not newer', () async {
      final service = serviceFor(200, releaseJson('v1.3.0'), current: '1.3.0');

      final result = await service.check();

      expect(result.status, UpdateStatus.upToDate);
    });

    test('does not call an older release an update', () async {
      // A rolled-back or hotfixed build must not be told to "update" to the
      // older tag that happens to be the latest published one.
      final service = serviceFor(200, releaseJson('v1.2.0'), current: '1.3.0');

      final result = await service.check();

      expect(result.status, UpdateStatus.upToDate);
    });

    test('treats a repository with no releases as a normal state', () async {
      final service = serviceFor(404, '{"message":"Not Found"}');

      final result = await service.check();

      expect(result.status, UpdateStatus.noReleasesYet);
      expect(result.message, isNull);
    });

    test('reports an unreachable GitHub without throwing', () async {
      final service = serviceFor(500, '{"message":"boom"}');

      final result = await service.check();

      expect(result.status, UpdateStatus.unreachable);
      expect(result.message, isNotNull);
    });

    test('reports a release with an unusable tag', () async {
      final service = serviceFor(200, '{"tag_name":""}');

      final result = await service.check();

      expect(result.status, UpdateStatus.unreachable);
      expect(result.message, contains('version tag'));
    });

    test('queries the repository it was configured with', () async {
      final dio = Dio();
      final fake = _FakeGitHub(200, releaseJson('v9.9.9'));
      dio.httpClientAdapter = fake;
      final service = UpdateService(
        dio: dio,
        currentVersion: '1.0.0',
        slug: 'someone/arcanum',
      );

      await service.check();

      expect(fake.requests.single.path, '/repos/someone/arcanum/releases/latest');
    });

    test('refuses to check before a repository is named', () async {
      final dio = Dio();
      final fake = _FakeGitHub(200, releaseJson('v9.9.9'));
      dio.httpClientAdapter = fake;
      // The placeholder shipped in the source until the project is published.
      final service = UpdateService(dio: dio, currentVersion: '1.0.0');

      expect(service.isConfigured, isFalse);
      final result = await service.check();

      expect(result.status, UpdateStatus.unreachable);
      // Nothing was asked of the network.
      expect(fake.requests, isEmpty);
    });
  });
}
