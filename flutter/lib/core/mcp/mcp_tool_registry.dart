import 'dart:convert';

import '../models.dart' show ToolCall;
import '../runtime/tool_registry.dart';
import '../tools/registry.dart' show ToolError, ToolSpec;
import 'mcp_client.dart';
import 'mcp_guard.dart';

/// Exposes MCP server tools to the agent engine. Tool names are prefixed
/// with the server name so different servers can never shadow each other or
/// the built-in tools, and every MCP call is treated as high-risk — the
/// policy default sends them to the approval flow.
///
/// Untrusted-content tagging (PHASE 48, lethal-trifecta mitigation): every
/// successful tool result is wrapped with `[不可信来源: MCP:<server>]` before
/// it can enter the model context — MCP output is attacker-writable and must
/// never be mistaken for user or system text. Error results stay as-is:
/// they surface as structured [McpException]/[ToolError], not content.
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

  /// PHASE 7: 当前可达的服务器 id 列表(按 config.id,去重,保持首次出现顺序)。
  List<String> get serverIds {
    final seen = <String>{};
    return [
      for (final entry in _entries)
        if (seen.add(entry.server.id)) entry.server.id,
    ];
  }

  /// PHASE 7: 指定服务器的工具 spec(按 config.id 匹配;该服务器不可达
  /// 或无工具时为空)。
  List<ToolSpec> specsFor(String serverId) => [
        for (final entry in _entries)
          if (entry.server.id == serverId)
            ToolSpec(
              toolId(entry.server.name, entry.info.name),
              entry.info.description.isEmpty
                  ? 'MCP 工具 ${entry.server.name}/${entry.info.name}'
                  : entry.info.description,
              'low',
            ),
      ];

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
        final result = await _client.callTool(
          entry.server,
          entry.info.name,
          arguments,
        );
        return _tagUntrusted(entry.server.name, result);
      }
    }
    throw ToolError('unknown tool: ${call.name}');
  }

  /// First line of the untrusted marker [McpGuard.tagUntrusted] stamps for
  /// an MCP server (see [_tagUntrusted]).
  static const _untrustedMarkerPrefix = '[不可信来源: MCP:';

  /// Untrusted-content tagging (PHASE 48, lethal-trifecta mitigation):
  /// everything an MCP server returns is attacker-writable, so a successful
  /// result must enter the agent context visibly marked with the server it
  /// came from ([serverName] is the routing key tools are namespaced by).
  /// Idempotent: a payload already starting with this server's own marker
  /// line (a server proxying another MCP call) is returned unchanged, so
  /// re-tagging never doubles the prefix. Foreign pre-existing markers do
  /// NOT suppress the tag — the true channel is always stamped on top.
  /// Error results never reach this: callTool surfaces them as structured
  /// [McpException]s, which stay untagged.
  static String _tagUntrusted(String serverName, String result) {
    if (result.startsWith('$_untrustedMarkerPrefix$serverName]')) {
      return result;
    }
    return McpGuard.tagUntrusted('MCP:$serverName', result);
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
