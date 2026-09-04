import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelly_hermes/core/mcp/mcp_client.dart';
import 'package:shelly_hermes/core/mcp/mcp_tool_registry.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/tools/registry.dart' show ToolError;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelly_hermes/state/settings_store.dart';

const _okInitResponse = {
  'jsonrpc': '2.0',
  'id': 1,
  'result': {
    'protocolVersion': '2025-03-26',
    'capabilities': {},
    'serverInfo': {'name': 'test-server', 'version': '1.0'},
  },
};

http.Response _json(Object payload) =>
    http.Response(jsonEncode(payload), 200, headers: {
      'mcp-session-id': 'sess-1',
      'content-type': 'application/json',
    });

McpServerConfig get _server => const McpServerConfig(
      id: 's1',
      name: 'github',
      url: 'https://mcp.example.com/mcp',
      token: 'tok',
    );

void main() {
  group('McpClient', () {
    test('initialize + tools/list round trip over JSON', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        final body =
            jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        if (body['method'] == 'initialize') return _json(_okInitResponse);
        if (body['method'] == 'notifications/initialized') {
          return http.Response('', 202);
        }
        return _json({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': {
            'tools': [
              {
                'name': 'create_issue',
                'description': '创建 issue',
                'inputSchema': {
                  'type': 'object',
                  'properties': {'title': {'type': 'string'}},
                },
              },
            ],
          },
        });
      });
      final mcp = McpClient(client: client);

      final tools = await mcp.listTools(_server);

      expect(tools, hasLength(1));
      expect(tools.single.name, 'create_issue');
      expect(tools.single.inputSchema, containsPair('type', 'object'));
      // Session id flows into subsequent requests.
      final listCall =
          bodies.where((b) => b['method'] == 'tools/list').single;
      expect(listCall, containsPair('method', 'tools/list'));
    });

    test('SSE responses are decoded from data: lines', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'initialize') return _json(_okInitResponse);
        if (body['method'] == 'notifications/initialized') {
          return http.Response('', 202);
        }
        final payload = jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': {'tools': []},
        });
        return http.Response(
          'event: message\ndata: $payload\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final mcp = McpClient(client: client);

      expect(await mcp.listTools(_server), isEmpty);
    });

    test('callTool joins text content and surfaces isError', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'initialize') return _json(_okInitResponse);
        if (body['method'] == 'notifications/initialized') {
          return http.Response('', 202);
        }
        if (body['method'] == 'tools/call') {
          final params = body['params'] as Map<String, dynamic>;
          if (params['name'] == 'boom') {
            return _json({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'isError': true,
                'content': [
                  {'type': 'text', 'text': '源仓库烧了'},
                ],
              },
            });
          }
          return _json({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {
              'content': [
                {'type': 'text', 'text': 'issue #42 已创建'},
              ],
            },
          });
        }
        throw StateError('unexpected ${body['method']}');
      });
      final mcp = McpClient(client: client);

      final text = await mcp.callTool(_server, 'create_issue', {'title': 'x'});
      expect(text, 'issue #42 已创建');

      await expectLater(
        mcp.callTool(_server, 'boom', {}),
        throwsA(isA<McpException>().having(
            (e) => e.message, 'message', contains('源仓库烧了'))),
      );
    });

    test('RPC errors and transport failures become McpException', () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'initialize') {
          return _json({
            'jsonrpc': '2.0',
            'id': body['id'],
            'error': {'code': -32000, 'message': 'denied'},
          });
        }
        throw StateError('unexpected');
      });
      final mcp = McpClient(client: client);

      await expectLater(
        mcp.listTools(_server),
        throwsA(isA<McpException>().having(
            (e) => e.message, 'message', contains('denied'))),
      );
    });
  });

  group('McpToolRegistry', () {
    McpClient scriptedClient(
        Map<String, Object?> Function(String method, Uri url) handler) {
      return McpClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final method = body['method'] as String;
          if (method == 'initialize') return _json(_okInitResponse);
          if (method == 'notifications/initialized') {
            return http.Response('', 202);
          }
          final result = handler(method, request.url);
          return _json({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': result,
          });
        }),
      );
    }

    test('connect discovers tools; failing servers are skipped', () async {
      final registry = await McpToolRegistry.connect([
        _server,
        const McpServerConfig(
            id: 'bad', name: 'bad', url: 'https://broken.example.com/mcp'),
      ], client: scriptedClient((method, url) {
        if (url.host == 'broken.example.com') {
          throw StateError('transport down');
        }
        return {
          'tools': [
            {'name': 'list_prs', 'description': '列出 PR'},
          ],
        };
      }));

      expect(registry.specs, hasLength(1));
      expect(registry.specs.single.name, 'mcp_github_list_prs');
      expect(registry.specs.single.risk, 'high');
    });

    test('openAiToolsJson passes through the MCP input schema', () async {
      final registry = await McpToolRegistry.connect([_server],
          client: scriptedClient((method, url) {
        return {
          'tools': [
            {
              'name': 'create_issue',
              'description': 'd',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'title': {'type': 'string'},
                },
              },
            },
          ],
        };
      }));

      final json = registry.openAiToolsJson();
      expect(json, hasLength(1));
      final function = json.single['function'] as Map<String, dynamic>;
      expect(function['name'], 'mcp_github_create_issue');
      expect(function['parameters'], {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
        },
      });
      expect(function['description'], startsWith('[MCP:github]'));
    });

    test('execute dispatches to the owning server', () async {
      final registry = await McpToolRegistry.connect([_server],
          client: scriptedClient((method, url) {
        if (method == 'tools/call') {
          return {
            'content': [
              {'type': 'text', 'text': 'issue #42 已创建'},
            ],
          };
        }
        return {
          'tools': [
            {'name': 'create_issue'},
          ],
        };
      }));

      final result = await registry.execute(ToolCall(
        id: 't1',
        name: 'mcp_github_create_issue',
        argumentsJson: '{"title":"hi"}',
      ));
      expect(result, 'issue #42 已创建');

      await expectLater(
        registry.execute(
            ToolCall(id: 't2', name: 'unknown', argumentsJson: '')),
        throwsA(isA<ToolError>()),
      );
    });
  });

  test('MCP server configs persist through the settings store', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());

    await store.saveMcpServers([
      const McpServerConfig(id: 's1', name: 'github',
          url: 'https://mcp.example.com/mcp', token: 'tok'),
    ]);
    final loaded = store.loadMcpServers();
    expect(loaded, hasLength(1));
    expect(loaded.single.name, 'github');
    expect(loaded.single.token, 'tok');

    await store.saveMcpServers(const []);
    expect(store.loadMcpServers(), isEmpty);
  });
}
