import 'dart:convert';

import '../models.dart' show ToolCall;
import '../runtime/tool_registry.dart';
import '../tools/registry.dart' show ToolError, ToolSpec;
import 'mcp_client.dart';

/// Exposes MCP server tools to the agent engine. Tool names are prefixed
/// with the server name so different servers can never shadow each other or
/// the built-in tools, and every MCP call is treated as high-risk — the
/// policy default sends them to the approval flow.
class McpToolRegistry implements AgentToolRegistry {
  McpToolRegistry({required List<McpToolEntry> tools, McpClient? client})
      : _entries = tools,
        _client = client ?? McpClient();

  /// Discovers tools from every configured server; servers that fail to
  /// respond are skipped (one broken endpoint must not break the agent).
  static Future<McpToolRegistry> connect(
    List<McpServerConfig> servers, {
    McpClient? client,
  }) async {
    final resolved = client ?? McpClient();
    final entries = <McpToolEntry>[];
    for (final server in servers) {
      if (server.url.trim().isEmpty) continue;
      try {
        final tools = await resolved.listTools(server);
        for (final tool in tools) {
          entries.add(McpToolEntry(server: server, info: tool));
        }
      } on McpException {
        // Skip silently; the environment page reports server health.
      }
    }
    return McpToolRegistry(tools: entries, client: resolved);
  }

  final List<McpToolEntry> _entries;
  final McpClient _client;

  /// `mcp_<server>_<tool>` with anything outside [a-zA-Z0-9_] collapsed.
  static String toolId(String serverName, String toolName) {
    String sanitize(String raw) => raw
        .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return 'mcp_${sanitize(serverName)}_${sanitize(toolName)}';
  }

  @override
  List<ToolSpec> get specs => [
        for (final entry in _entries)
          ToolSpec(
            toolId(entry.server.name, entry.info.name),
            entry.info.description.isEmpty
                ? 'MCP 工具 ${entry.server.name}/${entry.info.name}'
                : entry.info.description,
            // Third-party tools always require explicit approval.
            'high',
          ),
      ];

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        for (final entry in _entries)
          {
            'type': 'function',
            'function': {
              'name': toolId(entry.server.name, entry.info.name),
              'description': '[MCP:${entry.server.name}] '
                  '${entry.info.description}',
              'parameters':
                  entry.info.inputSchema ?? const {'type': 'object'},
            },
          },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    for (final entry in _entries) {
      if (toolId(entry.server.name, entry.info.name) == call.name) {
        final arguments = _decodeArguments(call.argumentsJson);
        return _client.callTool(entry.server, entry.info.name, arguments);
      }
    }
    throw ToolError('unknown tool: ${call.name}');
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
}

class McpToolEntry {
  const McpToolEntry({required this.server, required this.info});

  final McpServerConfig server;
  final McpToolInfo info;
}
