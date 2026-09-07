// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart' show ToolCall;
import '../runtime/tool_registry.dart' show AgentToolRegistry;
import '../tools/registry.dart' show ToolError, ToolSpec;

/// Thrown when the bridge is unreachable, rejects the token, answers an
/// invalid envelope, or times out — one readable message per failure.
class BridgeException implements Exception {
  BridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One tool advertised by the bridge catalog. `serverId` + `toolName` are
/// what `/call_tool` needs; the wire name is `<serverId>.<toolName>`.
class BridgeTool {
  const BridgeTool({
    required this.serverId,
    required this.serverName,
    required this.toolName,
    required this.description,
    this.inputSchema,
  });

  final String serverId;
  final String serverName;
  final String toolName;
  final String description;
  final Map<String, dynamic>? inputSchema;

  /// `<serverId>.<toolName>` as it appears on the wire.
  String get wireName => '$serverId.$toolName';
}

/// Consumes a desktop-side [BridgeServer](bridge_server.dart) over LAN HTTP
/// and exposes its tools through the standard `AgentToolRegistry` seam, so
/// the agent engine treats bridge tools exactly like core and MCP tools.
///
/// The catalog is fetched lazily on first use (memoized) or eagerly via
/// [refresh]. Local tool ids mirror `McpToolRegistry`: `bridge_<server>_<tool>`
/// with non-alphanumerics collapsed, because `.` is not a legal OpenAI
/// function-name character.
class BridgeToolRegistry implements AgentToolRegistry {
  BridgeToolRegistry({
    required this.baseUrl,
    required String token,
    http.Client? client,
    this.listTimeout = const Duration(seconds: 5),
    this.callTimeout = const Duration(seconds: 30),
  })  : _token = token,
        _client = client ?? http.Client();

  /// Bridge root, e.g. `http://192.168.1.10:8766`.
  final String baseUrl;
  final String _token;
  final http.Client _client;

  /// Timeout for `/list_tools` requests.
  final Duration listTimeout;

  /// Timeout for `/call_tool` requests.
  final Duration callTimeout;

  final List<ToolSpec> _specs = [];
  final Map<String, BridgeTool> _tools = {};
  final Map<String, Map<String, dynamic>?> _schemas = {};
  Future<void>? _loading;

  /// True once a catalog fetch has been kicked off.
  bool get isLoaded => _loading != null;

  int get toolCount => _specs.length;

  /// Fetches the catalog once; concurrent callers share the same future.
  Future<void> ensureLoaded() {
    return _loading ??= _fetchCatalog();
  }

  /// Re-fetches the catalog and rebuilds the tool list.
  Future<void> refresh() async {
    _loading = null;
    await ensureLoaded();
  }

  Future<void> _fetchCatalog() async {
    final payload = await _post('/list_tools', <String, dynamic>{},
        timeout: listTimeout);
    final tools = payload['tools'];
    final fresh = <String, BridgeTool>{};
    final freshSchemas = <String, Map<String, dynamic>?>{};
    if (tools is List) {
      for (final entry in tools) {
        if (entry is! Map<String, dynamic>) continue;
        final tool = BridgeTool(
          serverId: entry['server'] as String? ?? '',
          serverName: entry['serverName'] as String? ?? '',
          toolName: entry['tool'] as String? ?? '',
          description: entry['description'] as String? ?? '',
          inputSchema: entry['inputSchema'] is Map<String, dynamic>
              ? entry['inputSchema'] as Map<String, dynamic>
              : null,
        );
        if (tool.serverId.isEmpty || tool.toolName.isEmpty) continue;
        fresh[toolId(tool.serverId, tool.toolName)] = tool;
        freshSchemas[toolId(tool.serverId, tool.toolName)] = tool.inputSchema;
      }
    }
    _tools
      ..clear()
      ..addAll(fresh);
    _schemas
      ..clear()
      ..addAll(freshSchemas);
    _specs
      ..clear()
      ..addAll([
        for (final entry in _tools.entries)
          ToolSpec(
            entry.key,
            entry.value.description.isEmpty
                ? '桥接工具 ${entry.value.wireName}'
                : entry.value.description,
            // Third-party tools always require explicit approval.
            'high',
          ),
      ]);
  }

  /// `bridge_<server>_<tool>` with anything outside [a-zA-Z0-9_] collapsed.
  static String toolId(String serverId, String toolName) {
    String sanitize(String raw) => raw
        .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return 'bridge_${sanitize(serverId)}_${sanitize(toolName)}';
  }

  @override
  List<ToolSpec> get specs => List.unmodifiable(_specs);

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        for (final spec in _specs)
          {
            'type': 'function',
            'function': {
              'name': spec.name,
              'description': spec.description,
              'parameters':
                  _schemas[spec.name] ?? const {'type': 'object'},
            },
          },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    await ensureLoaded();
    final tool = _tools[call.name];
    if (tool == null) {
      throw ToolError('unknown tool: ${call.name}');
    }
    final payload = await _post(
      '/call_tool',
      {
        'server': tool.serverId,
        'tool': tool.toolName,
        'arguments': _decodeArguments(call.argumentsJson),
      },
      timeout: callTimeout,
    );
    return _resultText(payload);
  }

  Map<String, dynamic> _decodeArguments(String argumentsJson) {
    if (argumentsJson.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(argumentsJson);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }

  /// Extracts text content blocks (mirroring `McpClient.callTool`); falls
  /// back to the JSON encoding of the payload when there is no text.
  String _resultText(Map<String, dynamic> payload) {
    final content = payload['content'];
    final text = [
      if (content is List)
        for (final block in content)
          if (block is Map<String, dynamic> && block['type'] == 'text')
            block['text'] as String? ?? '',
    ].where((part) => part.isNotEmpty).join('\n');
    if (text.isNotEmpty) return text;
    if (payload.isEmpty) return '';
    return jsonEncode(payload);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    required Duration timeout,
  }) async {
    final uri = Uri.parse(baseUrl).resolve(path);
    final request = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..headers['X-Shelly-Bridge-Token'] = _token
      ..body = jsonEncode(body);
    http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw BridgeException('桥接服务响应超时');
    } catch (error) {
      throw BridgeException('无法连接桥接服务:$error');
    }
    return _decodeEnvelope(response);
  }

  Map<String, dynamic> _decodeEnvelope(http.Response response) {
    Map<String, dynamic> envelope;
    try {
      final decoded = jsonDecode(response.body);
      envelope =
          decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      throw BridgeException(
          '桥接服务返回无效 JSON (HTTP ${response.statusCode})');
    }
    if (response.statusCode == 401) {
      throw BridgeException('桥接服务鉴权失败 (401)');
    }
    if (response.statusCode >= 400) {
      throw BridgeException(
          envelope['error']?.toString() ?? '桥接服务返回 HTTP ${response.statusCode}');
    }
    if (envelope['ok'] != true) {
      throw BridgeException(
          envelope['error']?.toString() ?? '桥接服务调用失败');
    }
    final payload = envelope['payload'];
    return payload is Map<String, dynamic> ? payload : <String, dynamic>{};
  }
}
