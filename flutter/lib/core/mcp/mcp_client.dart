import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One configured MCP server (Streamable HTTP transport only — stdio is a
/// desktop concern and sockets are out of scope on Android).
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.token = '',
  });

  final String id;
  final String name;
  final String url;
  final String token;

  McpServerConfig copyWith({String? name, String? url, String? token}) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        token: token ?? this.token,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (token.isNotEmpty) 'token': token,
      };

  static McpServerConfig fromJson(Map<String, dynamic> json) =>
      McpServerConfig(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        token: json['token'] as String? ?? '',
      );
}

/// A tool advertised by an MCP server via `tools/list`.
class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.description,
    this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic>? inputSchema;
}

/// Thrown when an MCP server answers with a JSON-RPC error or a transport
/// failure, so callers can surface one readable message.
class McpException implements Exception {
  McpException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Minimal MCP client over Streamable HTTP: JSON-RPC 2.0 POSTs with SSE
/// responses decoded. Every operation opens a fresh session (initialize →
/// notifications/initialized → request), which keeps the client stateless
/// and immune to server-side session expiry.
class McpClient {
  McpClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  int _nextId = 1;

  static const _protocolVersion = '2025-03-26';

  Future<List<McpToolInfo>> listTools(McpServerConfig server) async {
    final result = await _roundTrip(server, 'tools/list', {});
    final tools = result['tools'];
    return [
      if (tools is List)
        for (final tool in tools)
          if (tool is Map<String, dynamic>)
            McpToolInfo(
              name: tool['name'] as String? ?? '',
              description: tool['description'] as String? ?? '',
              inputSchema: tool['inputSchema'] is Map<String, dynamic>
                  ? tool['inputSchema'] as Map<String, dynamic>
                  : null,
            ),
    ].where((tool) => tool.name.isNotEmpty).toList();
  }

  Future<String> callTool(
    McpServerConfig server,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final result = await _roundTrip(
      server,
      'tools/call',
      {'name': toolName, 'arguments': arguments},
    );
    final isError = result['isError'] == true;
    final content = result['content'];
    final text = [
      if (content is List)
        for (final block in content)
          if (block is Map<String, dynamic> && block['type'] == 'text')
            block['text'] as String? ?? '',
    ].where((part) => part.isNotEmpty).join('\n');
    if (isError) {
      throw McpException(text.isEmpty ? 'MCP 工具执行失败' : text);
    }
    return text;
  }

  Future<Map<String, dynamic>> _roundTrip(
    McpServerConfig server,
    String method,
    Map<String, dynamic> params,
  ) async {
    final session = await _initialize(server);
    return _rpc(server, method, params, sessionId: session);
  }

  /// Runs initialize + the initialized notification, returning the session
  /// id the server handed out (null when it manages none).
  Future<String?> _initialize(McpServerConfig server) async {
    final response = await _post(
      server,
      {
        'jsonrpc': '2.0',
        'id': _nextId++,
        'method': 'initialize',
        'params': {
          'protocolVersion': _protocolVersion,
          'capabilities': {},
          'clientInfo': {'name': 'shelly-hermes', 'version': '2.2.0'},
        },
      },
      sessionId: null,
    );
    _assertRpcOk(_parseBody(await _drain(response), response));
    final session = response.headers['mcp-session-id'];
    await _rpc(server, 'notifications/initialized', {},
        sessionId: session, notification: true);
    return session;
  }

  Future<Map<String, dynamic>> _rpc(
    McpServerConfig server,
    String method,
    Map<String, dynamic> params, {
    String? sessionId,
    bool notification = false,
  }) async {
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      if (!notification) 'id': _nextId++,
      'method': method,
      if (params.isNotEmpty) 'params': params,
    };
    final response = await _post(server, body, sessionId: sessionId);
    if (notification) return {};
    final payload = _parseBody(await _drain(response), response);
    return _assertRpcOk(payload);
  }

  Future<http.StreamedResponse> _post(
    McpServerConfig server,
    Map<String, dynamic> body, {
    required String? sessionId,
  }) async {
    final request = http.Request('POST', Uri.parse(server.url))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/json, text/event-stream'
      ..headers['MCP-Protocol-Version'] = _protocolVersion
      ..body = jsonEncode(body);
    if (server.token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${server.token}';
    }
    if (sessionId != null) {
      request.headers['Mcp-Session-Id'] = sessionId;
    }
    try {
      return await _client.send(request).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw McpException('MCP 服务器响应超时');
    } catch (error) {
      throw McpException('无法连接 MCP 服务器:$error');
    }
  }

  /// Decodes a JSON body or the `data:` lines of an SSE stream into the
  /// JSON-RPC payload.
  Map<String, dynamic> _parseBody(String raw, http.StreamedResponse response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw McpException('MCP 服务器返回 ${response.statusCode}');
    }
    final trimmed = raw.trimLeft();
    Map<String, dynamic> payload;
    if (trimmed.startsWith('event:') || trimmed.startsWith('data:')) {
      payload = _fromJsonLine(_lastDataLine(raw));
    } else {
      payload = _fromJsonLine(raw);
    }
    return payload;
  }

  Map<String, dynamic> _assertRpcOk(Map<String, dynamic> payload) {
    if (payload.containsKey('error')) {
      final error = payload['error'];
      final message =
          error is Map<String, dynamic> ? error['message'] : '$error';
      throw McpException('MCP 错误:$message');
    }
    final result = payload['result'];
    if (result is Map<String, dynamic>) return result;
    return {};
  }

  String _lastDataLine(String raw) {
    final lines = raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith('data:'))
        .toList();
    return lines.isEmpty ? '' : lines.last.substring(5).trim();
  }

  Map<String, dynamic> _fromJsonLine(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      throw McpException('MCP 响应不是有效的 JSON-RPC');
    }
  }

  Future<String> _drain(http.StreamedResponse response) async {
    final buffer = StringBuffer();
    await for (final chunk in response.stream) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
    }
    return buffer.toString();
  }
}
