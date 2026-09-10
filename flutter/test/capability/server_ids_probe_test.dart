import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/mcp/mcp_client.dart';
import 'package:shelly_hermes/core/mcp/mcp_tool_registry.dart';

void main() {
  test('serverIds getter returns deduped server ids', () {
    final registry = McpToolRegistry(tools: const [
      McpToolEntry(
        server: McpServerConfig(id: 'github', name: 'GitHub', url: 'u1'),
        info: McpToolInfo(name: 'search', description: '搜索'),
      ),
      McpToolEntry(
        server: McpServerConfig(id: 'github', name: 'GitHub-dup', url: 'u1'),
        info: McpToolInfo(name: 'search2', description: '搜索2'),
      ),
      McpToolEntry(
        server: McpServerConfig(id: 'db', name: 'DB', url: 'u2'),
        info: McpToolInfo(name: 'query', description: '查询'),
      ),
    ]);
    expect(registry.serverIds, ['github', 'db']);
  });
}
