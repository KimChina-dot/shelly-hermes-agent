import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/state/update_check.dart';

/// Fake transport for the update check: records every request and replays a
/// scripted response (or throws, simulating a network failure).
class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      handler;

  int callCount = 0;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    callCount += 1;
    requests.add(request.url);
    return handler(request);
  }
}

http.StreamedResponse _response(int status, [Map<String, dynamic>? body]) {
  final bytes = utf8.encode(body == null ? '' : jsonEncode(body));
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    contentLength: bytes.length,
    headers: {'content-type': 'application/json'},
  );
}

http.StreamedResponse _rawResponse(int status, String body) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    contentLength: bytes.length,
  );
}

Map<String, dynamic> _release({
  String tag = 'v2.2.0',
  String htmlUrl =
      'https://github.com/KimChina-dot/shelly-hermes-agent/releases/tag/v2.2.0',
  String? body = '## 更新内容\n- 修复若干问题',
}) =>
    {
      'tag_name': tag,
      'html_url': htmlUrl,
      'body': ?body,
      'name': 'Release $tag',
    };

Future<UpdateCheckService> _service(
  _FakeHttpClient client, {
  String currentVersion = '2.1.0',
  Map<String, String> prefsValues = const {},
  DateTime Function()? now,
}) async {
  SharedPreferences.setMockInitialValues(prefsValues);
  final prefs = await SharedPreferences.getInstance();
  return UpdateCheckService(
    client: client,
    prefs: prefs,
    currentVersion: currentVersion,
    now: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('version comparison', () {
    test('strips the leading v from release tags', () {
      expect(UpdateCheckService.normalizeVersion('v2.1.0'), '2.1.0');
      expect(UpdateCheckService.normalizeVersion('V2.1.0'), '2.1.0');
      expect(UpdateCheckService.normalizeVersion('2.1.0'), '2.1.0');
      expect(UpdateCheckService.normalizeVersion('  v2.1.0  '), '2.1.0');
      expect(UpdateCheckService.normalizeVersion('v'), isNull);
      expect(UpdateCheckService.normalizeVersion(''), isNull);
    });

    test('newer, older and equal with and without v prefix', () {
      expect(
        UpdateCheckService.compareVersions('v2.2.0', '2.1.0'),
        greaterThan(0),
      );
      expect(
        UpdateCheckService.compareVersions('2.0.9', 'v2.1.0'),
        lessThan(0),
      );
      expect(UpdateCheckService.compareVersions('v2.1.0', '2.1.0'), 0);
      expect(UpdateCheckService.compareVersions('v2.1.0', 'v2.1.0'), 0);
      expect(
        UpdateCheckService.compareVersions('v2.10.0', 'v2.9.9'),
        greaterThan(0),
      );
      expect(
        UpdateCheckService.compareVersions('v3.0.0', 'v2.99.99'),
        greaterThan(0),
      );
      expect(UpdateCheckService.compareVersions('2.1', '2.1.0'), 0);
      // A release outranks its own pre-releases (semver).
      expect(
        UpdateCheckService.compareVersions('2.1.0-beta.1', '2.1.0'),
        lessThan(0),
      );
      expect(
        UpdateCheckService.compareVersions('2.2.0', '2.2.0-rc.1'),
        greaterThan(0),
      );
    });

    test('service reports the normalized current version', () async {
      final client =
          _FakeHttpClient((request) async => _response(200, _release()));
      final service = await _service(client, currentVersion: 'v2.1.0');
      expect(service.currentVersion, '2.1.0');
    });
  });

  group('response parsing', () {
    test('parses tag, download url and release notes', () {
      final result = UpdateCheckService.parseRelease(
        _release(),
        currentVersion: '2.1.0',
      );
      expect(result, isNotNull);
      expect(result!.latestVersion, '2.2.0');
      expect(result.downloadUrl,
          'https://github.com/KimChina-dot/shelly-hermes-agent/releases/tag/v2.2.0');
      expect(result.notes, contains('修复若干问题'));
      expect(result.isNewer, isTrue);
    });

    test('flags equal and older releases as not newer', () {
      expect(
        UpdateCheckService.parseRelease(_release(tag: 'v2.1.0'),
                currentVersion: '2.1.0')!
            .isNewer,
        isFalse,
      );
      expect(
        UpdateCheckService.parseRelease(_release(tag: '2.0.9'),
                currentVersion: '2.1.0')!
            .isNewer,
        isFalse,
      );
    });

    test('truncates long release notes to ~500 characters', () {
      final result = UpdateCheckService.parseRelease(
        _release(body: 'a' * 600),
        currentVersion: '2.1.0',
      );
      expect(result!.notes.length, UpdateCheckService.maxNotesLength + 1);
      expect(result.notes.endsWith('…'), isTrue);
      expect(
        UpdateCheckService.parseRelease(
                _release(body: 'short'), currentVersion: '2.1.0')!
            .notes,
        'short',
      );
    });

    test('falls back to the repo releases page without html_url', () {
      final result = UpdateCheckService.parseRelease(
        _release(htmlUrl: ''),
        currentVersion: '2.1.0',
      );
      expect(result!.downloadUrl, UpdateCheckService.fallbackDownloadUrl);
    });

    test('returns null for unparsable releases', () {
      expect(
        UpdateCheckService.parseRelease({
          'html_url': 'https://example.com',
        }, currentVersion: '2.1.0'),
        isNull,
      );
      expect(
        UpdateCheckService.parseRelease(
            _release(tag: 'nightly'), currentVersion: '2.1.0'),
        isNull,
      );
      expect(
        UpdateCheckService.parseRelease(
            _release(body: null), currentVersion: '2.1.0')!
            .notes,
        '',
      );
    });
  });

  group('checkForUpdate', () {
    test('queries the GitHub releases endpoint for a newer release',
        () async {
      var fakeTime = DateTime(2026, 9, 6, 12);
      final client =
          _FakeHttpClient((request) async => _response(200, _release()));
      final service = await _service(client, now: () => fakeTime);

      final result = await service.checkForUpdate();

      expect(result, isNotNull);
      expect(result!.isNewer, isTrue);
      expect(result.latestVersion, '2.2.0');
      expect(client.callCount, 1);
      expect(client.requests.single, Uri.parse(UpdateCheckService.releasesUrl));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(UpdateCheckService.lastCheckKey),
        fakeTime.millisecondsSinceEpoch,
      );
    });

    test('24h cache skips the network unless forced', () async {
      var fakeTime = DateTime(2026, 9, 6, 12);
      final client =
          _FakeHttpClient((request) async => _response(200, _release()));
      final service = await _service(client, now: () => fakeTime);

      await service.checkForUpdate();
      expect(client.callCount, 1);

      // 23 hours later the cache is still fresh: no network, no result.
      fakeTime = fakeTime.add(const Duration(hours: 23));
      final cached = await service.checkForUpdate();
      expect(cached, isNull);
      expect(client.callCount, 1);
      expect(client.requests, hasLength(1));

      // force bypasses the fresh cache.
      final forced = await service.checkForUpdate(force: true);
      expect(forced, isNotNull);
      expect(client.callCount, 2);

      // 25 hours past the last (forced) check, an automatic check retries.
      fakeTime = fakeTime.add(const Duration(hours: 25));
      final stale = await service.checkForUpdate();
      expect(stale, isNotNull);
      expect(client.callCount, 3);
    });

    test('network failure returns null and is not cached', () async {
      final client = _FakeHttpClient(
          (request) async => throw http.ClientException('offline'));
      final service = await _service(client);

      final result = await service.checkForUpdate();

      expect(result, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(UpdateCheckService.lastCheckKey), isFalse);
      // The failed attempt never stamps the cache, so the next call retries.
      await service.checkForUpdate();
      expect(client.callCount, 2);
    });

    test('non-200 responses return null', () async {
      final client =
          _FakeHttpClient((request) async => _response(404));
      final service = await _service(client);
      expect(await service.checkForUpdate(), isNull);
      expect(client.callCount, 1);
    });

    test('malformed bodies return null instead of throwing', () async {
      final client = _FakeHttpClient(
          (request) async => _rawResponse(200, 'not json at all'));
      final service = await _service(client);
      expect(await service.checkForUpdate(), isNull);

      final listClient = _FakeHttpClient((request) async =>
          _rawResponse(200, jsonEncode([_release()])));
      final listService = await _service(listClient);
      expect(await listService.checkForUpdate(), isNull);
    });
  });
}
