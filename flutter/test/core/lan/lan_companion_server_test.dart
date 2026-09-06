import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/lan/lan_companion_server.dart';
import 'package:shelly_hermes/core/models.dart';

/// One companion response: status code, decoded JSON body and headers.
class _Resp {
  _Resp(this.status, this.body, this.headers);

  final int status;
  final dynamic body;
  final HttpHeaders headers;

  bool get corsWildcard =>
      headers.value('Access-Control-Allow-Origin') == '*';

  Map<String, dynamic> get map => body as Map<String, dynamic>;
}

Future<_Resp> _get(
  int port,
  String path, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    headers.forEach(request.headers.set);
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Resp(
      response.statusCode,
      text.isEmpty ? null : jsonDecode(text),
      response.headers,
    );
  } finally {
    client.close(force: true);
  }
}

final _fakeConversations = <Map<String, dynamic>>[
  {
    'id': 'c1',
    'title': 'First',
    'updatedAt': '2026-01-01T10:00:00.000',
    'messageCount': 4,
    'pinned': false,
    'modelId': 'gpt-test',
  },
  {
    'id': 'c2',
    'title': 'Second',
    'updatedAt': '2026-01-02T10:00:00.000',
    'messageCount': 2,
    'pinned': true,
  },
];

AgentCheckpoint _fakeCheckpoint() => AgentCheckpoint(
      messages: const [
        AgentMessage(role: MessageRole.user, content: '你好'),
        AgentMessage(role: MessageRole.assistant, content: '在的'),
      ],
      round: 3,
      consumedTokens: 42,
      toolCalls: 1,
    );

Future<(LanCompanionServer, int)> _startServer({
  String token = 'pair1234',
  String version = '1.2.3',
  String Function()? modelId,
  List<Map<String, dynamic>> Function()? conversations,
  AgentCheckpoint? Function(String)? checkpoint,
  DateTime Function()? clock,
}) async {
  final server = LanCompanionServer(
    port: 0,
    token: token,
    version: version,
    modelId: modelId,
    loadConversations: conversations,
    loadCheckpoint: checkpoint,
    clock: clock,
  );
  final bound = await server.start();
  expect(bound, isNotNull, reason: 'ephemeral bind should succeed in tests');
  return (server, bound!);
}

void main() {
  group('auth', () {
    test('401 JSON without a token and with a wrong token', () async {
      final (server, port) = await _startServer();
      addTearDown(server.stop);

      final missing = await _get(port, '/status');
      expect(missing.status, 401);
      expect(missing.map['error'], 'unauthorized');
      expect(missing.corsWildcard, isTrue);

      final wrongHeader =
          await _get(port, '/status', headers: {'X-Shelly-Token': 'nope'});
      expect(wrongHeader.status, 401);

      final wrongQuery = await _get(port, '/status?token=nope');
      expect(wrongQuery.status, 401);
    });

    test('accepts the token via the X-Shelly-Token header', () async {
      final (server, port) = await _startServer();
      addTearDown(server.stop);

      final response =
          await _get(port, '/status', headers: {'X-Shelly-Token': 'pair1234'});
      expect(response.status, 200);
    });

    test('accepts the token via the token query parameter', () async {
      final (server, port) = await _startServer(
        conversations: () => _fakeConversations,
        checkpoint: (id) => id == 'c1' ? _fakeCheckpoint() : null,
      );
      addTearDown(server.stop);

      final response = await _get(port, '/conversations?token=pair1234');
      expect(response.status, 200);

      final detail = await _get(port, '/conversation/c1?token=pair1234');
      expect(detail.status, 200);
    });
  });

  group('routes', () {
    test('/status payload shape with injected clock and model id',
        () async {
      var now = DateTime(2026, 1, 1, 12);
      final (server, port) = await _startServer(
        clock: () => now,
        modelId: () => 'gpt-test',
        conversations: () => _fakeConversations,
      );
      addTearDown(server.stop);

      // start() stamped startedAt from the injected clock; advancing it
      // afterwards must move the reported uptime.
      now = now.add(const Duration(seconds: 65));
      final response = await _get(port, '/status?token=pair1234');
      expect(response.status, 200);
      expect(response.corsWildcard, isTrue);
      expect(response.map, {
        'app': 'shelly-hermes',
        'version': '1.2.3',
        'uptimeSec': 65,
        'conversationCount': 2,
        'modelId': 'gpt-test',
      });
    });

    test('/conversations returns the injected summaries', () async {
      final (server, port) =
          await _startServer(conversations: () => _fakeConversations);
      addTearDown(server.stop);

      final response = await _get(port, '/conversations?token=pair1234');
      expect(response.status, 200);
      expect(response.body, hasLength(2));
      expect(response.body[0]['id'], 'c1');
      expect(response.body[0]['title'], 'First');
      expect(response.body[1]['pinned'], isTrue);
    });

    test('/conversations without a loader is an empty list', () async {
      final (server, port) = await _startServer();
      addTearDown(server.stop);

      final response = await _get(port, '/conversations?token=pair1234');
      expect(response.status, 200);
      expect(response.body, isEmpty);
    });

    test('/conversation/{id} returns checkpoint messages; 404 when absent',
        () async {
      final (server, port) = await _startServer(
        checkpoint: (id) => id == 'c1' ? _fakeCheckpoint() : null,
      );
      addTearDown(server.stop);

      final detail = await _get(port, '/conversation/c1?token=pair1234');
      expect(detail.status, 200);
      expect(detail.map['id'], 'c1');
      expect(detail.map['round'], 3);
      final messages = detail.map['messages'] as List<dynamic>;
      expect(messages, hasLength(2));
      expect(messages[0]['role'], 'user');
      expect(messages[0]['content'], '你好');
      expect(messages[1]['role'], 'assistant');
      expect(messages[1]['content'], '在的');

      final missing = await _get(port, '/conversation/unknown?token=pair1234');
      expect(missing.status, 404);
      expect(missing.map['error'], 'not_found');
    });

    test('unknown routes and bare /conversation give 404 JSON', () async {
      final (server, port) = await _startServer();
      addTearDown(server.stop);

      for (final path in ['/nope', '/conversation', '/']) {
        final response = await _get(port, '$path?token=pair1234');
        expect(response.status, 404, reason: path);
        expect(response.map['error'], 'not_found', reason: path);
        expect(response.corsWildcard, isTrue, reason: path);
      }
    });

    test('non-GET methods get 405 JSON', () async {
      final (server, port) = await _startServer();
      addTearDown(server.stop);

      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:$port/status?token=pair1234'),
      );
      final response = await request.close();
      expect(response.statusCode, 405);
      await response.drain<void>();
    });
  });

  group('failure handling', () {
    test('loader exceptions become 500 JSON and never kill the server',
        () async {
      var throwOnLoad = true;
      final (server, port) = await _startServer(
        conversations: () {
          if (throwOnLoad) throw StateError('boom');
          return _fakeConversations;
        },
      );
      addTearDown(server.stop);

      final broken = await _get(port, '/conversations?token=pair1234');
      expect(broken.status, 500);
      expect(broken.map['error'], 'internal_error');
      expect(broken.corsWildcard, isTrue);

      // The loop survived the exception — the loader recovers and /status
      // serves the count again.
      throwOnLoad = false;
      final healthy = await _get(port, '/status?token=pair1234');
      expect(healthy.status, 200);
      expect(healthy.map['conversationCount'], 2);
    });

    test('start() returns null instead of throwing on a taken port',
        () async {
      final (first, port) = await _startServer();
      addTearDown(first.stop);

      final second = LanCompanionServer(port: port, token: 'pair1234');
      expect(await second.start(), isNull);
      expect(second.isRunning, isFalse);
      await second.stop();
    });
  });

  test('start() is idempotent; stop() really closes the socket', () async {
    final (server, port) = await _startServer();
    expect(await server.start(), port);

    await server.stop();
    await server.stop(); // idempotent
    expect(server.isRunning, isFalse);

    var refused = false;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/status?token=pair1234'),
      );
      await request.close();
    } catch (_) {
      refused = true;
    } finally {
      client.close(force: true);
    }
    expect(refused, isTrue);
  });
}
