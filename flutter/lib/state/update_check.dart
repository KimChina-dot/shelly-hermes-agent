import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One completed update check: the latest GitHub release compared against
/// the running app version, plus what the profile page needs to render the
/// "new version" card and open the download page.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.latestVersion,
    required this.downloadUrl,
    required this.notes,
    required this.isNewer,
  });

  /// Latest release version, normalized without the leading `v`.
  final String latestVersion;

  /// Release page on GitHub (opens in the external browser).
  final String downloadUrl;

  /// Release notes excerpt, truncated to [UpdateCheckService.maxNotesLength].
  final String notes;

  /// Whether [latestVersion] is semantically newer than the running version.
  final bool isNewer;
}

/// In-app update check (PHASE 42). Queries the GitHub Releases API for the
/// latest release of this app, compares it against the installed version
/// (read from package_info_plus by the provider below) and caches the last
/// successful check in SharedPreferences so automatic checks hit the network
/// at most once per day.
///
/// The HTTP client is a plain injectable [http.Client] — deliberately not the
/// model gateway — so update checks stay independent of model configuration
/// and tests can fake the transport. Every entry point is failure-proof:
/// [checkForUpdate] never throws and returns null on any failure.
class UpdateCheckService {
  UpdateCheckService({
    http.Client? client,
    required this._prefs,
    required this._currentVersion,
    this.currentBuild = '',
    DateTime Function()? now,
  })  : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  final http.Client _client;
  final SharedPreferences _prefs;

  /// Installed version as reported by package_info_plus (may carry no `v`).
  final String _currentVersion;

  /// Installed build number, shown next to the version on the profile page.
  final String currentBuild;

  /// Injectable clock; production stamps [DateTime.now].
  final DateTime Function() _now;

  /// GitHub Releases endpoint for the latest release of this app.
  static const releasesUrl =
      'https://api.github.com/repos/KimChina-dot/shelly-hermes-agent/releases/latest';

  /// Fallback download page when the release has no `html_url`.
  static const fallbackDownloadUrl =
      'https://github.com/KimChina-dot/shelly-hermes-agent/releases/latest';

  /// SharedPreferences key storing the last successful check (epoch millis).
  static const lastCheckKey = 'shelly.update.lastcheck';

  /// Automatic checks inside this window skip the network entirely;
  /// `force: true` bypasses it (the profile page button passes force).
  static const cacheTtl = Duration(hours: 24);

  /// Release notes longer than this are truncated with an ellipsis.
  static const maxNotesLength = 500;

  /// Hard timeout for the release query.
  static const requestTimeout = Duration(seconds: 15);

  /// Installed version normalized (leading `v` stripped); '' when unknown.
  String get currentVersion => normalizeVersion(_currentVersion) ?? '';

  /// Queries the latest release. Returns null when the cache is fresh
  /// (unless [force]), on any network/parse failure, or when the release
  /// carries no parsable version tag. Never throws.
  Future<UpdateCheckResult?> checkForUpdate({bool force = false}) async {
    try {
      final now = _now();
      if (!force && _checkedRecently(now)) return null;
      final response = await _client
          .get(
            Uri.parse(releasesUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'shelly-hermes-agent',
            },
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map<String, dynamic>) return null;
      final result = parseRelease(json, currentVersion: _currentVersion);
      if (result == null) return null;
      await _prefs.setInt(lastCheckKey, now.millisecondsSinceEpoch);
      return result;
    } catch (_) {
      // Update checks must never introduce a failure.
      return null;
    }
  }

  /// Whether a successful check happened within [cacheTtl] before [now].
  bool _checkedRecently(DateTime now) {
    final last = _prefs.getInt(lastCheckKey);
    if (last == null) return false;
    return now.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
        cacheTtl;
  }

  /// Pure GitHub release parsing: reads `tag_name`, `html_url` and `body`,
  /// compares the tag against the current version and returns null when the
  /// tag carries no version-like content at all.
  static UpdateCheckResult? parseRelease(
    Map<String, dynamic> json, {
    required String currentVersion,
  }) {
    final tag = json['tag_name'] as String? ?? '';
    if (!RegExp(r'\d').hasMatch(tag)) return null;
    final latest = normalizeVersion(tag);
    if (latest == null || latest.isEmpty) return null;
    return UpdateCheckResult(
      latestVersion: latest,
      downloadUrl:
          (json['html_url'] as String?)?.trim().isNotEmpty == true
              ? json['html_url'] as String
              : fallbackDownloadUrl,
      notes: truncateNotes(json['body'] as String? ?? ''),
      isNewer: compareVersions(latest, currentVersion) > 0,
    );
  }

  /// Strips the leading `v`/`V` release-tag marker; null when nothing
  /// remains (or the input was empty).
  static String? normalizeVersion(String raw) {
    var value = raw.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    if (value.isEmpty) return null;
    return value;
  }

  /// Semantic version comparison tolerant of leading `v`, missing segments
  /// (2.1 == 2.1.0) and pre-release suffixes (a release outranks its own
  /// pre-releases: 2.1.0 > 2.1.0-beta.1). Returns a positive value when [a]
  /// is newer, negative when [b] is newer, 0 on ties.
  static int compareVersions(String a, String b) {
    final left = _parseVersion(a);
    final right = _parseVersion(b);
    final length =
        left.core.length > right.core.length ? left.core.length : right.core.length;
    for (var i = 0; i < length; i += 1) {
      final l = i < left.core.length ? left.core[i] : 0;
      final r = i < right.core.length ? right.core[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    if (left.prerelease != right.prerelease) {
      return left.prerelease ? -1 : 1;
    }
    return 0;
  }

  static ({List<int> core, bool prerelease}) _parseVersion(String version) {
    var value = normalizeVersion(version) ?? '';
    final build = value.indexOf('+');
    if (build >= 0) value = value.substring(0, build);
    final pre = value.indexOf('-');
    final hasPrerelease = pre >= 0;
    if (hasPrerelease) value = value.substring(0, pre);
    return (
      core: [for (final part in value.split('.')) _leadingInt(part)],
      prerelease: hasPrerelease,
    );
  }

  static int _leadingInt(String part) {
    final match = RegExp(r'^\d+').firstMatch(part);
    if (match == null) return 0;
    return int.tryParse(match.group(0)!) ?? 0;
  }

  /// Trims release notes and caps them at [maxNotesLength] characters.
  static String truncateNotes(String notes) {
    final trimmed = notes.trim();
    if (trimmed.length <= maxNotesLength) return trimmed;
    return '${trimmed.substring(0, maxNotesLength)}…';
  }
}

/// Loads the package info defensively: package_info_plus needs the platform
/// channel, which is unavailable in bare widget-test environments.
Future<PackageInfo> _loadPackageInfo() async {
  try {
    return await PackageInfo.fromPlatform();
  } catch (_) {
    return PackageInfo(
        appName: '', packageName: '', version: '', buildNumber: '');
  }
}

/// Reactive access for the profile page 关于 section; consistent with the
/// other SharedPreferences-backed store providers in this folder.
final updateCheckProvider = FutureProvider<UpdateCheckService>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final info = await _loadPackageInfo();
  return UpdateCheckService(
    prefs: prefs,
    currentVersion: info.version,
    currentBuild: info.buildNumber,
  );
});
