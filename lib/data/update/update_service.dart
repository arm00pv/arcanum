import 'package:dio/dio.dart';

/// Where Arcanum's own releases are published.
///
/// The update check is the one request the app makes that is not about cards or
/// prices, which is why it never runs on its own: it happens only when the user
/// asks for it from Settings.
const String arcanumReleaseSlug = 'OWNER/REPO';

/// A published release the app could move to.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.title,
    required this.notes,
    required this.url,
    this.publishedAt,
  });

  /// The version the tag names, with any leading "v" removed.
  final String version;

  /// The release's human title, falling back to the tag.
  final String title;

  /// The release body, as markdown.
  final String notes;

  /// The page a user should be sent to.
  final String url;

  final DateTime? publishedAt;

  factory ReleaseInfo.fromJson(Map<String, Object?> json) {
    final tag = (json['tag_name'] as String?)?.trim() ?? '';
    final title = (json['name'] as String?)?.trim() ?? '';
    final published = DateTime.tryParse((json['published_at'] as String?) ?? '');
    return ReleaseInfo(
      version: stripVersionPrefix(tag),
      title: title.isNotEmpty ? title : tag,
      notes: (json['body'] as String?) ?? '',
      url: (json['html_url'] as String?) ?? '',
      publishedAt: published,
    );
  }
}

/// What the app should tell the user after asking.
enum UpdateStatus {
  /// A newer release exists.
  updateAvailable,

  /// The running version is the newest published one.
  upToDate,

  /// The repository exists but has never published a release.
  noReleasesYet,

  /// GitHub could not be reached, or answered with something unusable.
  unreachable,
}

/// The result of one update check.
class UpdateResult {
  const UpdateResult({
    required this.status,
    required this.currentVersion,
    this.release,
    this.message,
  });

  final UpdateStatus status;
  final String currentVersion;

  /// The release found, when there was one.
  final ReleaseInfo? release;

  /// Why the check could not complete, when it could not.
  final String? message;
}

/// Removes a leading "v" or "V" from a version tag.
///
/// Tags are written "v1.2.0" by convention while pubspec writes "1.2.0", and
/// comparing the two without normalising would make every release look newer.
String stripVersionPrefix(String tag) {
  final s = tag.trim();
  if (s.length > 1 && (s.startsWith('v') || s.startsWith('V'))) {
    final rest = s.substring(1);
    // Only strip when a digit follows, so a version genuinely called "vortex"
    // is left alone.
    if (rest.isNotEmpty && rest.codeUnitAt(0) >= 0x30 && rest.codeUnitAt(0) <= 0x39) {
      return rest;
    }
  }
  return s;
}

/// Compares two dotted versions.
///
/// Returns a negative number when [a] is older than [b], zero when they are the
/// same, and a positive number when [a] is newer. Segments are compared
/// numerically rather than as text, because "1.10.0" is newer than "1.9.0" and
/// a string comparison says the opposite. A missing segment counts as zero, so
/// "1.2" and "1.2.0" are equal. Anything after a "-" is a pre-release and sorts
/// before the release it leads to.
int compareVersions(String a, String b) {
  List<int> core(String v) => stripVersionPrefix(v)
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();

  String pre(String v) {
    final parts = stripVersionPrefix(v).split('-');
    return parts.length > 1 ? parts.sublist(1).join('-') : '';
  }

  final left = core(a);
  final right = core(b);
  final length = left.length > right.length ? left.length : right.length;

  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l < r ? -1 : 1;
  }

  // Same numbers: a pre-release is older than the plain release.
  final lp = pre(a);
  final rp = pre(b);
  if (lp.isEmpty && rp.isEmpty) return 0;
  if (lp.isEmpty) return 1;
  if (rp.isEmpty) return -1;
  return lp.compareTo(rp);
}

/// Asks GitHub what the newest published release is.
///
/// Deliberately narrow: it reads one public endpoint and returns a value. It
/// never downloads an APK, never runs one, and never phones home on its own -
/// installing an update stays a decision the user makes in their browser or
/// their store.
class UpdateService {
  UpdateService({
    required Dio dio,
    required this.currentVersion,
    this.slug = arcanumReleaseSlug,
  }) : _dio = dio;

  final Dio _dio;

  /// The version currently installed, normally from the built package.
  final String currentVersion;

  /// The GitHub repository releases are published to.
  final String slug;

  /// Whether a check can be made at all.
  ///
  /// True once the repository has been named, which it is not until the project
  /// is actually published. The UI hides the check rather than offering a
  /// button that could only ever fail.
  bool get isConfigured =>
      slug.contains('/') && !slug.startsWith('OWNER') && slug.length > 3;

  /// The release page, for a caller that wants to open it without checking.
  String get releasesUrl => 'https://github.com/$slug/releases';

  Future<UpdateResult> check() async {
    if (!isConfigured) {
      return UpdateResult(
        status: UpdateStatus.unreachable,
        currentVersion: currentVersion,
        message: 'No release repository is configured for this build.',
      );
    }

    try {
      final res = await _dio.get<dynamic>(
        'https://api.github.com/repos/$slug/releases/latest',
        options: Options(
          headers: const <String, String>{
            'Accept': 'application/vnd.github+json',
          },
          // GitHub answers 404 when a repository has no releases at all, which
          // is a normal state rather than a failure, so it is not an error here.
          validateStatus: (int? code) => code != null && code < 500,
        ),
      );

      if (res.statusCode == 404) {
        return UpdateResult(
          status: UpdateStatus.noReleasesYet,
          currentVersion: currentVersion,
        );
      }
      if (res.statusCode != 200 || res.data is! Map) {
        return UpdateResult(
          status: UpdateStatus.unreachable,
          currentVersion: currentVersion,
          message: 'GitHub answered with status '
              '${res.statusCode?.toString() ?? 'unknown'}.',
        );
      }

      final release = ReleaseInfo.fromJson(
        Map<String, Object?>.from(res.data as Map),
      );
      if (release.version.isEmpty) {
        return UpdateResult(
          status: UpdateStatus.unreachable,
          currentVersion: currentVersion,
          message: 'The newest release had no usable version tag.',
        );
      }

      final newer = compareVersions(release.version, currentVersion) > 0;
      return UpdateResult(
        status: newer ? UpdateStatus.updateAvailable : UpdateStatus.upToDate,
        currentVersion: currentVersion,
        release: release,
      );
    } on DioException catch (error) {
      return UpdateResult(
        status: UpdateStatus.unreachable,
        currentVersion: currentVersion,
        message: error.message ?? 'GitHub could not be reached.',
      );
    } catch (error) {
      return UpdateResult(
        status: UpdateStatus.unreachable,
        currentVersion: currentVersion,
        message: error.toString(),
      );
    }
  }
}
