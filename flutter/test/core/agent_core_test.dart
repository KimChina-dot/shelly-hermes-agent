import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/models.dart';

/// Scripted model: replays queued replies, then keeps returning the last one.
class FakeModel implements ModelGateway {
  final List<ModelReply> script;
  final List<List<AgentMessage>> calls = [];

  FakeModel(this.script);

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    calls.add(List.of(messages));
    return script.length <= 1 ? script.first : script.removeAt(0);
  }
}

class FakeTools implements ToolExecutor {
  final Map<String, String> outcomes = {};
  final List<ToolCall> executed = [];
  Object? throwOn;

  @override
  Future<String> execute(ToolCall call) async {
    if (throwOn != null) throw throwOn!;
    executed.add(call);
    return outcomes[call.name] ?? 'ok:${call.name}';
  }
}

/// Approval gateway resolving from a queue; empty queue means approve all.
class QueueApprovals implements ApprovalGateway {
  final List<ApprovalDecision> decisions;
  final List<ToolCall> requests = [];

  QueueApprovals([this.decisions = const []]);

  @override
  Future<ApprovalDecision> request(ToolCall call) async {
    requests.add(call);
    return decisions.isEmpty ? ApprovalDecision.approve : decisions.removeAt(0);
  }
}

class MemoryCheckpoints implements CheckpointStore {
  final List<AgentCheckpoint> saved = [];

  @override
  Future<void> save(AgentCheckpoint checkpoint) async => saved.add(checkpoint);
}

AgentMessage userMsg(String text) => AgentMessage(role: MessageRole.user, content: text);

void main() {
  test('completes when the model returns plain content', () async {
    final model = FakeModel([const ModelReply(content: '你好,世界')]);
    final checkpoints = MemoryCheckpoints();
    final core = AgentCore(
      model: model,
      tools: FakeTools(),
      approvals: QueueApprovals(),
      checkpoints: checkpoints,
    );

    final result = await core.run([userMsg('hi')], CancelFlag());

    expect(result, isA<AgentCompleted>());
    expect((result as AgentCompleted).message, '你好,世界');
    expect(result.checkpoint.messages.last.role, MessageRole.assistant);
    expect(checkpoints.saved, isNotEmpty);
  });

  test('executes an approved tool call and feeds the result back', () async {
    final model = FakeModel([
      const ModelReply(content: '', toolCalls: [
        ToolCall(id: 't1', name: 'list_files', argumentsJson: '{}'),
      ]),
      const ModelReply(content: 'done'),
    ]);
    final tools = FakeTools()..outcomes['list_files'] = 'a.txt\nb.txt';
    final approvals = QueueApprovals();
    final core = AgentCore(
      model: model,
      tools: tools,
      approvals: approvals,
      checkpoints: MemoryCheckpoints(),
    );

    final result = await core.run([userMsg('列出文件')], CancelFlag());

    expect((result as AgentCompleted).message, 'done');
    expect(tools.executed.single.name, 'list_files');
    expect(approvals.requests.single.id, 't1');
    final toolMessage = model.calls[1].last;
    expect(toolMessage.role, MessageRole.tool);
    expect(toolMessage.content, 'a.txt\nb.txt');
    expect(toolMessage.toolCallId, 't1');
  });

  test('rejected tool call records a rejection tool message without executing',
      () async {
    final model = FakeModel([
      const ModelReply(content: '', toolCalls: [
        ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}'),
      ]),
      const ModelReply(content: 'understood'),
    ]);
    final tools = FakeTools();
    final core = AgentCore(
      model: model,
      tools: tools,
      approvals: QueueApprovals([ApprovalDecision.reject]),
      checkpoints: MemoryCheckpoints(),
    );

    await core.run([userMsg('hi')], CancelFlag());

    expect(tools.executed, isEmpty);
    final toolMessage = model.calls[1].last;
    expect(toolMessage.role, MessageRole.tool);
    expect(toolMessage.content, 'Tool call rejected by user');
  });

  test('apply_patch approval expands into per-hunk calls and collapses the '
      'approved subset', () async {
    final model = FakeModel([
      const ModelReply(content: '', toolCalls: [
        ToolCall(
          id: 'p1',
          name: 'apply_patch',
          argumentsJson: '{"path":"lib/a.dart","patch":"@@ -1,2 +1,2 @@\\n-a\\n+b\\n@@ -3,2 +3,2 @@\\n-c\\n+d"}',
        ),
      ]),
      const ModelReply(content: 'patched'),
    ]);
    final tools = FakeTools();
    final approvals = QueueApprovals([
      ApprovalDecision.approve,
      ApprovalDecision.reject,
    ]);
    final core = AgentCore(
      model: model,
      tools: tools,
      approvals: approvals,
      checkpoints: MemoryCheckpoints(),
    );

    await core.run([userMsg('apply')], CancelFlag());

    // Two hunks requested individually; user approved only the first.
    expect(approvals.requests.map((r) => r.id), ['p1:hunk-1', 'p1:hunk-2']);
    expect(tools.executed.single.name, 'apply_patch');
    expect(tools.executed.single.id, 'p1');
    // Only the approved hunk survives in the collapsed patch.
    expect(tools.executed.single.argumentsJson, isNot(contains('-c')));
  });

  test('read-only policy bypasses approval for trusted tools', () async {
    final model = FakeModel([
      const ModelReply(content: '', toolCalls: [
        ToolCall(id: 't1', name: 'read_file', argumentsJson: '{}'),
      ]),
      const ModelReply(content: 'done'),
    ]);
    final approvals = QueueApprovals();
    final core = AgentCore(
      model: model,
      tools: FakeTools(),
      approvals: approvals,
      checkpoints: MemoryCheckpoints(),
      approvalPolicy: AutoApproveReadOnlyPolicy(),
    );

    await core.run([userMsg('hi')], CancelFlag());

    expect(approvals.requests, isEmpty);
  });

  test('broken approval policy fails closed to requiring approval', () async {
    final model = FakeModel([
      const ModelReply(content: '', toolCalls: [
        ToolCall(id: 't1', name: 'read_file', argumentsJson: '{}'),
      ]),
      const ModelReply(content: 'done'),
    ]);
    final approvals = QueueApprovals();
    final core = AgentCore(
      model: model,
      tools: FakeTools(),
      approvals: approvals,
      checkpoints: MemoryCheckpoints(),
      approvalPolicy: _ThrowingPolicy(),
    );

    await core.run([userMsg('hi')], CancelFlag());

    // Fail closed: the request was still routed to the human gateway.
    expect(approvals.requests, isNotEmpty);
  });

  test('cancellation before a round returns stopped with checkpoint',
      () async {
    final core = AgentCore(
      model: FakeModel([const ModelReply(content: 'x')]),
      tools: FakeTools(),
      approvals: QueueApprovals(),
      checkpoints: MemoryCheckpoints(),
    );
    final flag = CancelFlag()..cancel();

    final result = await core.run([userMsg('hi')], flag);

    expect(result, isA<AgentStopped>());
    expect((result as AgentStopped).reason, 'cancelled');
  });

  test('round limit returns stopped', () async {
    final model = FakeModel([
      const ModelReply(content: '', toolCalls: [
        ToolCall(id: 't1', name: 'noop', argumentsJson: '{}'),
      ]),
    ]);
    final core = AgentCore(
      model: model,
      tools: FakeTools(),
      approvals: QueueApprovals(),
      checkpoints: MemoryCheckpoints(),
      limits: const AgentLimits(maxRounds: 2, maxToolCalls: 100),
    );

    final result = await core.run([userMsg('hi')], CancelFlag());

    expect((result as AgentStopped).reason, 'round_limit_exceeded');
  });

  test('token budget exceeded returns stopped', () async {
    final core = AgentCore(
      model: FakeModel([const ModelReply(content: 'x', inputTokens: 70000)]),
      tools: FakeTools(),
      approvals: QueueApprovals(),
      checkpoints: MemoryCheckpoints(),
    );

    final result = await core.run([userMsg('hi')], CancelFlag());

    expect((result as AgentStopped).reason, 'token_budget_exceeded');
  });

  test('resume from awaitingExecution executes without re-asking approval',
      () async {
    const pendingCall = ToolCall(id: 't9', name: 'write_file', argumentsJson: '{}');
    final resume = AgentCheckpoint(
      messages: [userMsg('hi'), const AgentMessage(role: MessageRole.assistant, content: '', toolCalls: [pendingCall])],
      round: 1,
      consumedTokens: 10,
      toolCalls: 1,
      pendingToolCalls: const [
        PendingToolCall(call: pendingCall, stage: ToolExecutionStage.awaitingExecution),
      ],
    );
    final model = FakeModel([const ModelReply(content: 'resumed-done')]);
    final approvals = QueueApprovals();
    final core = AgentCore(
      model: model,
      tools: FakeTools()..outcomes['write_file'] = 'written',
      approvals: approvals,
      checkpoints: MemoryCheckpoints(),
    );

    final result = await core.run([userMsg('hi')], CancelFlag(), resumeFrom: resume);

    expect(approvals.requests, isEmpty);
    expect((result as AgentCompleted).message, 'resumed-done');
    expect(model.calls.single.last.content, 'written');
  });

  test('resume with RUNNING stage demotes to awaitingApproval and asks again',
      () async {
    const pendingCall = ToolCall(id: 't9', name: 'write_file', argumentsJson: '{}');
    final resume = AgentCheckpoint(
      messages: const [],
      round: 1,
      consumedTokens: 10,
      toolCalls: 1,
      pendingToolCalls: [
        PendingToolCall(call: pendingCall, stage: ToolExecutionStage.running),
      ],
    );
    final model = FakeModel([const ModelReply(content: 'done')]);
    final approvals = QueueApprovals([ApprovalDecision.approve]);
    final core = AgentCore(
      model: model,
      tools: FakeTools(),
      approvals: approvals,
      checkpoints: MemoryCheckpoints(),
    );

    await core.run(const [], CancelFlag(), resumeFrom: resume);

    // The human must confirm explicitly; execution is not silently rerun.
    expect(approvals.requests.single.id, 't9');
  });

  test('observer receives lifecycle events and cannot break the loop',
      () async {
    final events = <AgentEvent>[];
    final core = AgentCore(
      model: FakeModel([const ModelReply(content: 'hi there')]),
      tools: FakeTools(),
      approvals: QueueApprovals(),
      checkpoints: MemoryCheckpoints(),
      observer: _ThrowingObserver(events),
    );

    await core.run([userMsg('hi')], CancelFlag());

    expect(events.whereType<ModelStarted>(), isNotEmpty);
    expect(events.whereType<ModelFinished>(), isNotEmpty);
  });

  test('streaming gateway deltas are surfaced as ModelDelta events', () async {
    final events = <AgentEvent>[];
    final core = AgentCore(
      model: _StreamingFakeModel(),
      tools: FakeTools(),
      approvals: QueueApprovals(),
      checkpoints: MemoryCheckpoints(),
      observer: _CollectingObserver(events),
    );

    final result = await core.run([userMsg('hi')], CancelFlag());

    expect((result as AgentCompleted).message, 'streamed');
    expect(
      events.whereType<ModelDelta>().map((e) => e.text).join(),
      'stred',
    );
  });
}

class _ThrowingPolicy implements ToolApprovalPolicy {
  @override
  bool requiresApproval(ToolCall call) => throw StateError('broken policy');
}

class _ThrowingObserver implements AgentObserver {
  _ThrowingObserver(this.events);

  final List<AgentEvent> events;

  @override
  void onEvent(AgentEvent event) {
    events.add(event);
    throw StateError('observer exploded');
  }
}

class _CollectingObserver implements AgentObserver {
  _CollectingObserver(this.events);

  final List<AgentEvent> events;

  @override
  void onEvent(AgentEvent event) => events.add(event);
}

class _StreamingFakeModel implements StreamingModelGateway {
  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async =>
      const ModelReply(content: 'streamed');

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String) onDelta,
  ) async {
    onDelta('str');
    onDelta('e');
    onDelta('d');
    return const ModelReply(content: 'streamed');
  }
}
