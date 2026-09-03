import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/gateway/openai_gateway.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/runtime/agent_context.dart';
import 'package:shelly_hermes/core/runtime/agent_runtime.dart';
import 'package:shelly_hermes/core/runtime/tool_registry.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

class _ScriptedModel implements StreamingModelGateway {
  _ScriptedModel(this.replies);

  final List<ModelReply> replies;
  List<List<AgentMessage>> seenMessages = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seenMessages = [List.of(messages)];
    return replies.removeAt(0);
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) =>
      complete(messages);
}

class _NoopApprovals implements ApprovalGateway {
  @override
  Future<ApprovalDecision> request(ToolCall call) async => ApprovalDecision.approve;
}

class _NoopCheckpoints implements CheckpointStore {
  @override
  Future<void> save(AgentCheckpoint checkpoint) async {}
}

class _PluginTools implements AgentToolRegistry {
  int calls = 0;

  @override
  List<ToolSpec> get specs => const [
        ToolSpec('flutter_doctor', '插件提供的诊断工具', 'low'),
      ];

  @override
  List<Map<String, dynamic>> openAiToolsJson() => const [];

  @override
  Future<String> execute(ToolCall call) async {
    calls += 1;
    return 'plugin result';
  }
}

class _RecordingMemory implements AgentMemoryAccess {
  _RecordingMemory(this.knowledge);

  final List<String> knowledge;
  final List<String> recalled = [];
  final List<String> remembered = [];

  @override
  Future<List<String>> recall(String task) async {
    recalled.add(task);
    return knowledge;
  }

  @override
  Future<void> maybeRemember(String finalReply, AgentCheckpoint checkpoint) async {
    remembered.add(finalReply);
  }
}

AgentContext _context({
  required ModelGateway model,
  AgentToolRegistry? tools,
  AgentMemoryAccess? hermes,
}) {
  return AgentContext(
    sessionId: 'test',
    workspace: MemoryWorkspace(),
    model: model,
    tools: tools ?? CompositeToolRegistry([_PluginTools()]),
    checkpoints: _NoopCheckpoints(),
    hermes: hermes,
  );
}

void main() {
  test('composite registry merges specs and dispatches to the owning child', () async {
    final plugin = _PluginTools();
    final registry = CompositeToolRegistry([
      WorkspaceToolRegistry(workspace: MemoryWorkspace()),
      plugin,
    ]);
    expect(registry.specs.map((s) => s.name),
        containsAll(['read_file', 'write_file', 'flutter_doctor']));

    final reply = await registry.execute(
      ToolCall(id: 't1', name: 'flutter_doctor', argumentsJson: '{}'),
    );
    expect(reply, 'plugin result');
    expect(plugin.calls, 1);
  });

  test('composite registry rejects unknown tools without touching children', () async {
    final plugin = _PluginTools();
    final registry = CompositeToolRegistry([plugin]);
    await expectLater(
      registry.execute(ToolCall(id: 't2', name: 'nope', argumentsJson: '{}')),
      throwsA(isA<ToolError>()),
    );
    expect(plugin.calls, 0);
  });

  test('runtime injects recalled knowledge as a system message before the run',
      () async {
    final model = _ScriptedModel([
      const ModelReply(content: '完成', toolCalls: [], inputTokens: 1, outputTokens: 1),
    ]);
    final memory = _RecordingMemory(['该项目使用 Riverpod']);
    final runtime = AgentRuntime(
      context: _context(model: model, hermes: memory),
      approvals: _NoopApprovals(),
    );

    final result = await runtime.run(
      [const AgentMessage(role: MessageRole.user, content: '修复登录')],
      CancelFlag(),
    );

    expect(result, isA<AgentCompleted>());
    final seen = model.seenMessages.single;
    expect(seen.first.role, MessageRole.system);
    expect(seen.first.content, contains('该项目使用 Riverpod'));
    expect(seen.last.content, '修复登录');
    expect(memory.recalled, ['修复登录']);
  });

  test('runtime offers the final reply to memory on completion', () async {
    final model = _ScriptedModel([
      const ModelReply(
          content: '已修复,经验:先检查 mounted',
          toolCalls: [],
          inputTokens: 1,
          outputTokens: 1),
    ]);
    final memory = _RecordingMemory(const []);
    final runtime = AgentRuntime(
      context: _context(model: model, hermes: memory),
      approvals: _NoopApprovals(),
    );

    await runtime.run(
      [const AgentMessage(role: MessageRole.user, content: '修复登录')],
      CancelFlag(),
    );

    expect(memory.remembered, ['已修复,经验:先检查 mounted']);
  });

  test('memory failures never break the agent loop', () async {
    final model = _ScriptedModel([
      const ModelReply(content: 'done', toolCalls: [], inputTokens: 1, outputTokens: 1),
    ]);
    final memory = _BrokenMemory();
    final runtime = AgentRuntime(
      context: _context(model: model, hermes: memory),
      approvals: _NoopApprovals(),
    );

    final result = await runtime.run(
      [const AgentMessage(role: MessageRole.user, content: '任务')],
      CancelFlag(),
    );

    expect(result, isA<AgentCompleted>());
  });

  test('resume tasks skip memory injection', () async {
    final model = _ScriptedModel([
      const ModelReply(content: 'ok', toolCalls: [], inputTokens: 1, outputTokens: 1),
    ]);
    final memory = _RecordingMemory(['经验']);
    final runtime = AgentRuntime(
      context: _context(model: model, hermes: memory),
      approvals: _NoopApprovals(),
    );

    await runtime.run(
      [const AgentMessage(role: MessageRole.user, content: '继续任务')],
      CancelFlag(),
      resumeFrom: const AgentCheckpoint(
        messages: [AgentMessage(role: MessageRole.user, content: '继续任务')],
        round: 1,
        consumedTokens: 10,
        toolCalls: 0,
        pendingToolCalls: [],
      ),
    );

    expect(memory.recalled, isEmpty);
    final seen = model.seenMessages.single;
    expect(seen.where((m) => m.role == MessageRole.system), isEmpty);
  });

  test('gateway request body advertises tools when provided', () async {
    ChatRequest? captured;
    final transport = _CapturingTransport((request) => captured = request);
    final gateway = OpenAiCompatibleGateway(
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'k',
      model: 'm',
      tools: WorkspaceToolRegistry(workspace: MemoryWorkspace()).openAiToolsJson(),
      transport: transport,
    );

    await gateway.complete([
      const AgentMessage(role: MessageRole.user, content: 'hi'),
    ]);

    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    final tools = body['tools'] as List<dynamic>;
    expect(tools, hasLength(6));
    final read = tools.first as Map<String, dynamic>;
    expect(read['type'], 'function');
    expect(read['function']['name'], 'read_file');
    expect(read['function']['parameters']['required'], ['path']);
  });
}

class _BrokenMemory implements AgentMemoryAccess {
  @override
  Future<List<String>> recall(String task) async => throw StateError('boom');

  @override
  Future<void> maybeRemember(String finalReply, AgentCheckpoint checkpoint) async {
    throw StateError('boom');
  }
}

class _CapturingTransport implements ChatTransport {
  _CapturingTransport(this.onRequest);

  final void Function(ChatRequest request) onRequest;

  @override
  Future<ChatResponse> post(ChatRequest request) async {
    onRequest(request);
    return const ChatResponse(
      statusCode: 200,
      body: '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}',
    );
  }

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async {
    onRequest(request);
    return ChatStreamResponse(
      statusCode: 200,
      chunks: Stream.value(jsonEncode({
        'choices': [
          {
            'delta': {'content': 'ok'},
          }
        ],
      })),
    );
  }
}
