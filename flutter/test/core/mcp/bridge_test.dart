import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shelly_hermes/core/mcp/bridge_client.dart';
import 'package:shelly_hermes/core/mcp/bridge_server.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/tools/registry.dart' show ToolError;

// ---------------------------------------------------------------------------
// Controllable fake process
// ---------------------------------------------------------------------------

/// Scripted stdio MCP server. Responds to initialize / tools/list /
/// tools/call like a real server, and can be told to hang or die.
class FakeProcess implements BridgeProcess {
  final _stdinController = StreamController<String>();
  final _stdoutController = StreamController<String>.broadcast();
  final _doneCompleter = Completer<void>();
  StreamSubscription<String>? _listener;
  int killCount = 0;

  /// Tools this fake advertises after handshake.
  List<Map<String, dynamic>> tools = [
    {
      'name': 'echo',
      'description': 'Echo back the input',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
    },
  ];

  /// Call log of (method, params) pairs.
  final List<Map<String, Object?>> requests = [];

  /// When non-empty, tools/call for this tool name answers with this result
  /// object instead of the default echo text.
  final Map<String, Map<String, dynamic>> structuredResults = {};

  /// When true, no response is ever sent to tools/call (timeout tests).
  bool hangCalls = false;

  /// When true the fake completes [done] as soon as it is killed.
  bool dieOnKill = true;

  @override
  Stream<String> get stdoutLines => _stdoutController.stream;

  @override
  void writeLine(String line) {
    _listener ??= _stdinController.stream.listen(_handleRequest);
    _stdinController.add(line);
  }

  @override
  void kill() {
    killCount++;
    if (dieOnKill) exit();
  }

  @override
  Future<void> get done => _doneCompleter.future;

  /// Emits one line on the fake stdout.
  void emitLine(String line) => _stdoutController.add(line);

  /// Emits a JSON-RPC response/event as a line.
  void emitJson(Object? payload) => emitLine(jsonEncode(payload));

  /// Simulates the process exiting.
  void exit() {
    if (_doneCompleter.isCompleted) return;
    _doneCompleter.complete();
    _listener?.cancel();
  }

  void _handleRequest(String line) {
    final Map<String, dynamic> request;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;
      request = decoded;
    } on FormatException {
      return;
    }
    final method = request['method'] as String? ?? '';
    requests.add({'method': method, 'params': request['params']});
    final id = request['id'];
    switch (method) {
      case 'initialize':
        emitJson({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2025-03-26',
            'capabilities': <String, dynamic>{},
            'serverInfo': {'name': 'fake', 'version': '1.0'},
          },
        });
      case 'notifications/initialized':
        break;
      case 'tools/list':
        emitJson({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'tools': tools},
        });
      case 'tools/call':
        if (hangCalls) return;
        final params = request['params'] as Map<String, dynamic>? ?? {};
        final toolName = params['name'] as String? ?? '';
        if (!tools.any((tool) => tool['name'] == toolName)) {
          emitJson({
            'jsonrpc': '2.0',
            'id': id,
            'error': {
              'code': -32602,
              'message': 'unknown tool: $toolName',
            },
          });
          return;
        }
        final custom = structuredResults[toolName];
        if (custom != null) {
          emitJson({'jsonrpc': '2.0', 'id': id, 'result': custom});
          return;
        }
        final args = params['arguments'] as Map<String, dynamic>? ?? {};
        emitJson({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {
                'type': 'text',
                'text': 'echo:$toolName:${args['text'] ?? ''}',
              }
            ],
          },
        });
      default:
        if (id != null) {
          emitJson({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'method not found: $method'},
          });
        }
    }
  }
}

/// Records spawn calls and hands out fresh [FakeProcess]es. [throwOnCall]
/// makes every spawn fail; [onSpawn] customizes each fake before handoff.
class _RecordingSpawner {
  final List<FakeProcess> processes = [];
  final List<BridgeStdioServerDef> defs = [];
  Object? throwOnCall;
  void Function(FakeProcess process)? onSpawn;

  Future<BridgeProcess> spawn(BridgeStdioServerDef def) async {
    if (throwOnCall != null) throw throwOnCall!;
    defs.add(def);
    final process = FakeProcess();
    onSpawn?.call(process);
    processes.add(process);
    return process;
  }
}

BridgeStdioServerDef _def(String id) => BridgeStdioServerDef(
      id: id,
      name: '$id server',
      command: 'fake-$id',
      args: const ['--stdio'],
      env: {'FAKE': id},
    );

BridgeServer _server(
  List<BridgeStdioServerDef> defs,
  BridgeProcessSpawner spawner, {
  String token = '',
}) =>
    BridgeServer(
      config: BridgeConfig(servers: defs, token: token),
      spawner: spawner,
      // Short backoff so respawn-based tests stay fast.
      restartBackoffBase: const Duration(milliseconds: 50),
    );

Future<http.Response> _post(
  Uri url, {
  String? token,
  Object? body,
}) {
  final request = http.Request('POST', url)
    ..headers['Content-Type'] = 'application/json'
    ..body = jsonEncode(body ?? <String, dynamic>{});
  if (token != null) request.headers['X-Shelly-Bridge-Token'] = token;
  return request.send().then(http.Response.fromStream);
}

Future<Map<String, dynamic>> _json(http.Response response) async =>
    jsonDecode(response.body) as Map<String, dynamic>;

void main() {
  group('handshake and catalog caching', () {
    test('performs initialize → initialized → tools/list per server',
        () async {
      final spawner = _RecordingSpawner();
      final server = _server([_def('a'), _def('b')], spawner.spawn);
      await server.start(port: 0);
      addTearDown(server.stop);

      expect(spawner.processes, hasLength(2));
      for (final process in spawner.processes) {
        expect(
          process.requests.map((r) => r['method']),
          ['initialize', 'notifications/initialized', 'tools/list'],
        );
      }
    });

    test('tools/list is cached — reading the catalog does not re-query',
        () async {
      final spawner = _RecordingSpawner();
      final server = _server([_def('a')], spawner.spawn);
      await server.start(port: 0);
      addTearDown(server.stop);

      final first = server.catalog();
      final second = server.catalog();
      expect(first, equals(second));
      final toolsListRequests = spawner.processes.single.requests
          .where((r) => r['method'] == 'tools/list')
          .length;
      expect(toolsListRequests, 1);
    });

    test('catalog naming is <serverId>.<toolName> with schema passthrough',
        () async {
      final spawner = _RecordingSpawner();
      final server = _server([_def('a')], spawner.spawn);
      await server.start(port: 0);
      addTearDown(server.stop);

      final catalog = server.catalog();
      expect(catalog, hasLength(1));
      expect(catalog.single['name'], 'a.echo');
      expect(catalog.single['server'], 'a');
      expect(catalog.single['serverName'], 'a server');
      expect(catalog.single['tool'], 'echo');
      expect(catalog.single['description'], 'Echo back the input');
      expect(catalog.single['inputSchema'], {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      });
    });

    test('spawn failure does not block startup; server marked not alive',
        () async {
      final spawner = _RecordingSpawner()
        ..throwOnCall = StateError('spawn failed');
      final server = BridgeServer(
        config: BridgeConfig(servers: [_def('a')], token: ''),
        spawner: spawner.spawn,
        // Keep the retry loop slow so it cannot spin during the test.
        restartBackoffBase: const Duration(seconds: 5),
      );
      await server.start(port: 0);
      addTearDown(server.stop);

      expect(spawner.processes, isEmpty);
      expect(server.catalog(), isEmpty);
      final health = server.healthPayload();
      expect(health['ok'], true);
      expect((health['servers'] as List).single['alive'], false);
    });
  });

  group('HTTP surface', () {
    late _RecordingSpawner spawner;
    late BridgeServer server;
    late Uri base;

    setUp(() async {
      spawner = _RecordingSpawner();
      server = _server([_def('a'), _def('b')], spawner.spawn, token: 'secret');
      await server.start(port: 0);
      addTearDown(server.stop);
      base = Uri.parse('http://127.0.0.1:${server.port}');
    });

    test('POST /list_tools merges catalogs with per-tool schemas', () async {
      spawner.processes[1].tools = [
        {
          'name': 'git_status',
          'description': 'Show git status',
          'inputSchema': {'type': 'object'},
        },
      ];
      // b's catalog was cached at handshake, so change it before start?
      // No: restart is triggered by killing the child. Instead verify the
      // merge with the default two catalogs of the same shape.
      final response =
          await _post(base.replace(path: '/list_tools'), token: 'secret');
      expect(response.statusCode, 200);
      final body = await _json(response);
      expect(body['ok'], true);
      final tools = (body['payload'] as Map)['tools'] as List;
      expect(tools, hasLength(2));
      final names = tools.map((t) => t['name']).toSet();
      expect(names, {'a.echo', 'b.echo'});
      final echo = tools.firstWhere((t) => t['name'] == 'a.echo');
      expect(echo['server'], 'a');
      expect(echo['serverName'], 'a server');
      expect(echo['inputSchema']['properties'], isNotNull);
    });

    test('POST /call_tool routes to the right child and passes the result',
        () async {
      final response = await _post(
        base.replace(path: '/call_tool'),
        token: 'secret',
        body: {
          'server': 'b',
          'tool': 'echo',
          'arguments': {'text': 'hello'},
        },
      );
      expect(response.statusCode, 200);
      final body = await _json(response);
      expect(body['ok'], true);
      final payload = body['payload'] as Map;
      expect(payload['content'][0]['text'], 'echo:echo:hello');
      // The call went to process #2 (server b), not a.
      final aCallCount = spawner.processes[0].requests
          .where((r) => r['method'] == 'tools/call')
          .length;
      expect(aCallCount, 0);
      final last = spawner.processes[1].requests.last;
      expect(last['method'], 'tools/call');
      expect((last['params'] as Map)['name'], 'echo');
      expect((last['params'] as Map)['arguments'], {'text': 'hello'});
    });

    test('POST /call_tool with unknown server answers 404 envelope',
        () async {
      final response = await _post(
        base.replace(path: '/call_tool'),
        token: 'secret',
        body: {'server': 'nope', 'tool': 'echo'},
      );
      expect(response.statusCode, 404);
      final body = await _json(response);
      expect(body['ok'], false);
      expect(body['error'], contains('nope'));
    });

    test('POST /call_tool surfaces child JSON-RPC error as {ok:false}',
        () async {
      final response = await _post(
        base.replace(path: '/call_tool'),
        token: 'secret',
        body: {'server': 'a', 'tool': 'does_not_exist', 'arguments': {}},
      );
      expect(response.statusCode, 200);
      final body = await _json(response);
      expect(body['ok'], false);
      expect(body['error'], contains('does_not_exist'));
    });

    test('GET /health reports per-server liveness and tool counts', () async {
      final response = await http
          .get(base.replace(path: '/health'),
              headers: {'X-Shelly-Bridge-Token': 'secret'})
          .timeout(const Duration(seconds: 10));
      expect(response.statusCode, 200);
      final body = await _json(response);
      expect(body['ok'], true);
      final servers = body['servers'] as List;
      expect(servers, hasLength(2));
      expect(servers.map((s) => s['id']).toSet(), {'a', 'b'});
      expect(servers.every((s) => s['alive'] == true), isTrue);
      expect(servers.every((s) => s['toolCount'] == 1), isTrue);
    });

    test('missing token answers 401', () async {
      final response = await _post(base.replace(path: '/list_tools'));
      expect(response.statusCode, 401);
      final body = await _json(response);
      expect(body['ok'], false);
      expect(body['error'], 'unauthorized');
    });

    test('wrong token answers 401', () async {
      final response =
          await _post(base.replace(path: '/list_tools'), token: 'wrong');
      expect(response.statusCode, 401);
    });

    test('health also requires the token', () async {
      final response = await http
          .get(base.replace(path: '/health'))
          .timeout(const Duration(seconds: 10));
      expect(response.statusCode, 401);
    });

    test('unknown route answers 404 with an error envelope', () async {
      final response = await http
          .get(base.replace(path: '/nope'),
              headers: {'X-Shelly-Bridge-Token': 'secret'})
          .timeout(const Duration(seconds: 10));
      expect(response.statusCode, 404);
      final body = await _json(response);
      expect(body['ok'], false);
    });

    test('invalid JSON body answers 400', () async {
      final request = http.Request(
        'POST',
        base.replace(path: '/call_tool'),
      )..headers.addAll({
          'Content-Type': 'application/json',
          'X-Shelly-Bridge-Token': 'secret',
        });
      request.body = '{not json';
      final response =
          await request.send().then(http.Response.fromStream);
      expect(response.statusCode, 400);
      final body = await _json(response);
      expect(body['ok'], false);
    });

    test('missing server/tool fields answer 400', () async {
      final response = await _post(
        base.replace(path: '/call_tool'),
        token: 'secret',
        body: {'server': 'a'},
      );
      expect(response.statusCode, 400);
    });

    test('merge uses each server after respawn (fresh catalog per handshake)',
        () async {
      // The replacement process must advertise the new tool set.
      spawner.onSpawn = (process) {
        process.tools = [
          {
            'name': 'git_status',
            'description': 'Show git status',
            'inputSchema': {'type': 'object'},
          },
        ];
      };
      // Kill b; its respawn must re-handshake and cache the updated tools.
      spawner.processes[1].exit();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final response =
          await _post(base.replace(path: '/list_tools'), token: 'secret');
      final body = await _json(response);
      final tools = (body['payload'] as Map)['tools'] as List;
      expect(tools.map((t) => t['name']).toSet(), {'a.echo', 'b.git_status'});
    });
  });

  group('restart on death', () {
    test('respawns the child with backoff and refreshes the catalog',
        () async {
      final spawner = _RecordingSpawner();
      final server = BridgeServer(
        config: BridgeConfig(servers: [_def('a')], token: ''),
        spawner: spawner.spawn,
        restartBackoffBase: const Duration(milliseconds: 50),
      );
      await server.start(port: 0);
      addTearDown(server.stop);

      final original = spawner.processes.single;
      expect(server.catalog(), isNotEmpty);

      original.exit();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(spawner.processes, hasLength(2));
      final replacement = spawner.processes.last;
      expect(identical(original, replacement), isFalse);
      expect(
        replacement.requests.map((r) => r['method']),
        ['initialize', 'notifications/initialized', 'tools/list'],
      );
      expect(server.catalog(), isNotEmpty);
      expect(server.healthPayload()['servers'].single['alive'], true);
    });

    test('backoff grows between repeated failures', () async {
      // Spawner that succeeds only on the third attempt.
      var attempts = 0;
      Future<BridgeProcess> flaky(BridgeStdioServerDef def) async {
        attempts++;
        if (attempts < 3) throw StateError('flaky $attempts');
        return FakeProcess();
      }

      final server = BridgeServer(
        config: BridgeConfig(servers: [_def('a')], token: ''),
        spawner: flaky,
        restartBackoffBase: const Duration(milliseconds: 40),
      );
      await server.start(port: 0);
      addTearDown(server.stop);

      // Initial spawn fails twice (40 ms, then 80 ms backoff), third
      // attempt succeeds and completes a handshake.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(attempts, 3);
      expect(server.catalog(), isNotEmpty);
      expect(server.healthPayload()['servers'].single['alive'], true);
    });

    test('exit after stop() does not schedule a restart', () async {
      final spawner = _RecordingSpawner();
      final server = BridgeServer(
        config: BridgeConfig(servers: [_def('a')], token: ''),
        spawner: spawner.spawn,
        restartBackoffBase: const Duration(milliseconds: 50),
      );
      await server.start(port: 0);
      final process = spawner.processes.single;
      await server.stop();
      process.exit();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(spawner.processes, hasLength(1));
    });
  });

  group('BridgeToolRegistry (loopback)', () {
    late _RecordingSpawner spawner;
    late BridgeServer bridge;
    late Uri base;

    setUp(() async {
      spawner = _RecordingSpawner();
      bridge = _server([_def('a')], spawner.spawn, token: 'secret');
      await bridge.start(port: 0);
      addTearDown(bridge.stop);
      base = Uri.parse('http://127.0.0.1:${bridge.port}');
    });

    test('lazy catalog fetch builds specs and OpenAI definitions', () async {
      final registry = BridgeToolRegistry(
        baseUrl: '$base',
        token: 'secret',
      );
      expect(registry.isLoaded, false);
      await registry.ensureLoaded();
      expect(registry.isLoaded, true);
      final specs = registry.specs;
      expect(specs, hasLength(1));
      expect(specs.single.name, 'bridge_a_echo');
      expect(specs.single.description, 'Echo back the input');
      expect(specs.single.risk, 'high');

      final openAi = registry.openAiToolsJson();
      expect(openAi.single['type'], 'function');
      final function = openAi.single['function'] as Map;
      expect(function['name'], 'bridge_a_echo');
      expect(function['parameters']['properties'], isNotNull);
    });

    test('execute() posts /call_tool and returns the text payload',
        () async {
      final registry = BridgeToolRegistry(
        baseUrl: '$base',
        token: 'secret',
      );
      final result = await registry.execute(const ToolCall(
        id: 't1',
        name: 'bridge_a_echo',
        argumentsJson: '{"text":"hi"}',
      ));
      expect(result, 'echo:echo:hi');
    });

    test('execute() with non-text payload returns JSON encoding', () async {
      spawner.processes.single.structuredResults['echo'] = {
        'content': [
          {'type': 'image', 'data': 'x1y2'},
        ],
      };
      final registry = BridgeToolRegistry(
        baseUrl: '$base',
        token: 'secret',
      );
      await registry.ensureLoaded();
      final result = await registry.execute(const ToolCall(
        id: 't2',
        name: 'bridge_a_echo',
        argumentsJson: '{}',
      ));
      expect(result, contains('image'));
      expect(result, contains('x1y2'));
    });

    test('refresh() picks up tools added after a respawn', () async {
      final registry = BridgeToolRegistry(
        baseUrl: '$base',
        token: 'secret',
      );
      await registry.ensureLoaded();
      expect(registry.toolCount, 1);

      // The bridge caches the catalog per handshake, so the child must be
      // replaced for a new tool to appear.
      spawner.onSpawn = (process) {
        process.tools = [
          ...process.tools,
          {'name': 'extra', 'description': 'Second tool'},
        ];
      };
      spawner.processes.single.exit();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await registry.refresh();
      expect(registry.toolCount, 2);
      expect(registry.specs.map((s) => s.name), contains('bridge_a_extra'));
    });

    test('401 becomes a structured BridgeException', () async {
      final registry = BridgeToolRegistry(
        baseUrl: '$base',
        token: 'wrong',
      );
      await expectLater(
        registry.ensureLoaded(),
        throwsA(isA<BridgeException>()),
      );
      // The memoized failed load also surfaces on execute().
      await expectLater(
        registry.execute(const ToolCall(
          id: 't3',
          name: 'bridge_a_echo',
          argumentsJson: '{}',
        )),
        throwsA(isA<BridgeException>()),
      );
    });

    test('connection refused becomes a structured BridgeException',
        () async {
      // Grab a port nothing is listening on.
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final registry = BridgeToolRegistry(
        baseUrl: 'http://127.0.0.1:$deadPort',
        token: 'secret',
      );
      await expectLater(
        registry.ensureLoaded(),
        throwsA(isA<BridgeException>()),
      );
    });

    test('list timeout surfaces as BridgeException', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        request.response.write(jsonEncode({
          'ok': true,
          'payload': {'tools': []},
        }));
        await request.response.close();
      });
      addTearDown(server.close);

      final registry = BridgeToolRegistry(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'secret',
        listTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        registry.ensureLoaded(),
        throwsA(isA<BridgeException>()),
      );
    });

    test('call timeout surfaces as BridgeException', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/list_tools') {
          request.response.write(jsonEncode({
            'ok': true,
            'payload': {
              'tools': [
                {
                  'name': 'a.slow',
                  'server': 'a',
                  'tool': 'slow',
                  'description': 'slow tool',
                }
              ]
            },
          }));
          await request.response.close();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        request.response.write(jsonEncode({'ok': true, 'payload': {}}));
        await request.response.close();
      });
      addTearDown(server.close);

      final registry = BridgeToolRegistry(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'secret',
        callTimeout: const Duration(milliseconds: 30),
      );
      await registry.ensureLoaded();
      await expectLater(
        registry.execute(const ToolCall(
          id: 't4',
          name: 'bridge_a_slow',
          argumentsJson: '{}',
        )),
        throwsA(isA<BridgeException>()),
      );
    });

    test('unknown tool id raises ToolError', () async {
      final registry = BridgeToolRegistry(
        baseUrl: '$base',
        token: 'secret',
      );
      await registry.ensureLoaded();
      await expectLater(
        registry.execute(const ToolCall(
          id: 't5',
          name: 'bridge_a_missing',
          argumentsJson: '{}',
        )),
        throwsA(isA<ToolError>()),
      );
    });

    test('child hang surfaces as {ok:false} through the envelope', () async {
      final hangSpawner = _RecordingSpawner()
        ..onSpawn = (process) => process.hangCalls = true;
      final tightBridge = BridgeServer(
        config: BridgeConfig(servers: [_def('a')], token: 'secret'),
        spawner: hangSpawner.spawn,
        callTimeout: const Duration(milliseconds: 100),
      );
      await tightBridge.start(port: 0);
      addTearDown(tightBridge.stop);

      final registry = BridgeToolRegistry(
        baseUrl: 'http://127.0.0.1:${tightBridge.port}',
        token: 'secret',
      );
      await registry.ensureLoaded();
      await expectLater(
        registry.execute(const ToolCall(
          id: 't6',
          name: 'bridge_a_echo',
          argumentsJson: '{}',
        )),
        throwsA(isA<BridgeException>()),
      );
    });
  });

  group('BridgeConfig parsing', () {
    test('fromJsonList keeps ids, args, and env', () {
      final config = BridgeConfig.fromJsonList([
        {
          'id': 'filesys',
          'name': 'Filesystem',
          'command': 'node',
          'args': ['fs.js', '--watch'],
          'env': {'HOME': '/x'},
        },
      ]);
      expect(config.servers, hasLength(1));
      expect(config.servers.single.id, 'filesys');
      expect(config.servers.single.args, ['fs.js', '--watch']);
      expect(config.servers.single.env, {'HOME': '/x'});
    });
  });
}
