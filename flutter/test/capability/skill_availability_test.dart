/// PHASE 17 — real capability availability behind the skill tools.
///
/// The availability set is derived from what a task assembly actually
/// registers (`availableCapabilityIds`), and the [SkillToolRegistry] gate
/// consumes it instead of the PHASE 9 admit-everything placeholder. Three
/// levels are covered:
/// - builder: each assembly signal maps to the documented capability id,
///   and anything not actually up contributes nothing (拿不到的不注册);
/// - skill gate: the default real set (filesystem + terminal — exactly what
///   `_TaskRunner.run` registers on a plain task) hands out the
///   android_debugging roadmap, while a set missing 'terminal' returns an
///   error naming terminal;
/// - session: a scripted gateway drives the REAL chat-session assembly
///   (`chatGatewayOverrideProvider`) through a `use_skill` tool call,
///   proving the production wiring admits the skill end to end.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/capability/skills/skill_tool_registry.dart';
import 'package:shelly_hermes/capability/skills/task_capability_availability.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/dsh/manifest.dart';
import 'package:shelly_hermes/core/dsh/plugin.dart';
import 'package:shelly_hermes/core/dsh/registry.dart';
import 'package:shelly_hermes/core/dsh/tool_registry.dart';
import 'package:shelly_hermes/core/mcp/bridge_client.dart';
import 'package:shelly_hermes/core/mcp/mcp_client.dart';
import 'package:shelly_hermes/core/mcp/mcp_tool_registry.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/skills/builtin_skills.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Gateway stub mirroring the steering-test harness: replays canned replies,
/// records every engine round. Brain prefills come through the
/// non-streaming path and consume the same script without being recorded.
class _ScriptedGateway implements StreamingModelGateway {
  _ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  final List<List<AgentMessage>> seen = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    return replies.removeAt(0);
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    seen.add(List.of(messages));
    final reply = replies.removeAt(0);
    if (reply.content.isNotEmpty) onDelta(reply.content);
    return reply;
  }
}

ToolCall _call(String name, String argumentsJson) => ToolCall(
      id: 'call-1',
      name: name,
      argumentsJson: argumentsJson,
    );

SkillToolRegistry _skillToolsOver(Set<String> available) =>
    SkillToolRegistry(
      registry: buildBuiltinSkillRegistry(),
      isCapabilityAvailable: available.contains,
    );

McpToolRegistry _mcpWithAnsweredServer() => McpToolRegistry(tools: [
      McpToolEntry(
        server: const McpServerConfig(
          id: 'github',
          name: 'GitHub',
          url: 'http://127.0.0.1:1', // never dialed: entries are seeded
        ),
        info: const McpToolInfo(name: 'create_issue', description: 'x'),
      ),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('availableCapabilityIds (assembly signal → capability id)', () {
    test('default assembly registers exactly filesystem + terminal', () {
      final ids = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
      );

      expect(ids, {'filesystem', 'terminal'});
    });

    test('MCP servers that answered discovery map to mcp_<serverId>; '
        'absent registry contributes nothing', () {
      final withMcp = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
        mcpRegistry: _mcpWithAnsweredServer(),
      );
      expect(withMcp, contains('mcp_github'));

      final withoutMcp = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
        // Unset servers (empty config, timeout fallback, all unreachable)
        // never produce ids: an empty registry has no serverIds.
        mcpRegistry: McpToolRegistry(tools: const []),
      );
      expect(
        withoutMcp.where((id) => id.startsWith('mcp_')),
        isEmpty,
      );
    });

    test('a loaded bridge contributes the channel id; no bridge, no id',
        () {
      final withBridge = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
        bridgeRegistry: BridgeToolRegistry(
          baseUrl: 'http://127.0.0.1:1',
          token: 't',
        ),
      );
      expect(withBridge, contains('bridge'));

      final withoutBridge = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
      );
      expect(withoutBridge.contains('bridge'), isFalse);
    });

    test('enabled DSH plugins contribute their manifest id; registered-only '
        'plugins do not', () async {
      final pluginRegistry = DshPluginRegistry();
      const manifestId = 'dev.test.weather';
      pluginRegistry.register(
        ShellPlugin(
          const DshManifest(
            id: manifestId,
            name: '天气查询',
            version: '1.0.0',
            description: '测试插件',
            author: 'test',
            runtime: 'shell',
            tools: [
              DshToolDecl(
                  name: 'run', description: '执行一条命令', command: 'echo'),
            ],
          ),
        ),
      );

      final notEnabledYet = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
        dshTools: DshToolRegistry(
          pluginRegistry: pluginRegistry,
          trustPolicy: DshTrustPolicy(),
        ),
      );
      expect(notEnabledYet.contains(manifestId), isFalse);

      await pluginRegistry.load(manifestId);
      await pluginRegistry.enable(manifestId);
      final enabled = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
        dshTools: DshToolRegistry(
          pluginRegistry: pluginRegistry,
          trustPolicy: DshTrustPolicy(),
        ),
      );
      expect(enabled, contains(manifestId));
    });
  });

  group('skill gate over the real id-set shape', () {
    test('real registered set hands out the android_debugging roadmap',
        () async {
      final available = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: true,
      );

      final output = await _skillToolsOver(available)
          .execute(_call('use_skill', '{"id": "android_debugging"}'));

      expect(output, contains('Android 构建调试'));
      expect(output, contains('技能指引'));
    });

    test('set missing terminal returns an error naming terminal', () async {
      // The production assembly registers the shell unconditionally, so a
      // terminal-less task only exists at unit level — same builder, shell
      // signal off.
      final available = availableCapabilityIds(
        workspaceRegistered: true,
        shellRegistered: false,
      );
      expect(available.contains('terminal'), isFalse);

      final output = await _skillToolsOver(available)
          .execute(_call('use_skill', '{"id": "android_debugging"}'));

      expect(output, startsWith('error:'));
      expect(output, contains('terminal'));
      expect(output, isNot(contains('技能指引')));
    });
  });

  group('chat_session real assembly path', () {
    test('use_skill(android_debugging) returns the roadmap through the '
        'production wiring', () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _ScriptedGateway([
        // One Brain classify prefill (PHASE 8) consumes the first reply.
        const ModelReply(content: 'quickAnswer'),
        const ModelReply(toolCalls: [
          ToolCall(
            id: 'call-1',
            name: 'use_skill',
            argumentsJson: '{"id": "android_debugging"}',
          ),
        ]),
        const ModelReply(content: 'done'),
      ]);
      final container = ProviderContainer(overrides: [
        chatGatewayOverrideProvider.overrideWith((ref) => gateway),
      ]);
      addTearDown(container.dispose);
      final store = SettingsStore(await SharedPreferences.getInstance());
      final controller = container.read(chatSessionProvider.notifier);
      controller.attach(store);

      await controller.send('帮我修构建错误');
      for (var i = 0; i < 500; i += 1) {
        if (!container.read(chatSessionProvider).isBusy) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(container.read(chatSessionProvider).isBusy, isFalse,
          reason: 'chat task did not return to idle');

      // Two engine rounds: round 1 issues the use_skill call, round 2 sees
      // its result. The tool message in round 2's request is what the REAL
      // assembly's availability set ('filesystem' + 'terminal') let
      // through — the roadmap, not a denial string.
      expect(gateway.seen, hasLength(2));
      final toolMessages = [
        for (final message in gateway.seen.last)
          if (message.role == MessageRole.tool) message,
      ];
      expect(toolMessages, hasLength(1));
      final roadmap = toolMessages.single.content;
      expect(roadmap, contains('Android 构建调试'));
      expect(roadmap, contains('技能指引'));
      expect(roadmap, isNot(startsWith('error:')));
    });
  });
}
