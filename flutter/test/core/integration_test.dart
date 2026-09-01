import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/tools/audit.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

/// Full-chain integration test: scripted model → WorkspaceToolRegistry on a
/// MemoryWorkspace → ApprovalBroker → JsonlAuditLog, mirroring how the UI
/// layer wires the engine in production.
void main() {
  test('agent edits a file end-to-end: read, patch with approval, done',
      () async {
    final workspace = MemoryWorkspace({'app.dart': 'int answer = 41;\n'});
    final broker = ApprovalBroker();
    final sink = InMemoryAuditSink();
    final audit = JsonlAuditLog(sink: sink, clock: () => DateTime(2026, 1, 1));

    final core = AgentCore(
      model: _ScriptedModel([
        const ModelReply(
          content: '',
          toolCalls: [
            ToolCall(id: 'r1', name: 'read_file', argumentsJson: '{"path":"app.dart"}'),
          ],
        ),
        const ModelReply(
          content: '',
          toolCalls: [
            ToolCall(
              id: 'p1',
              name: 'apply_patch',
              argumentsJson:
                  '{"path":"app.dart","patch":"@@ -1 +1 @@\\n-int answer = 41;\\n+int answer = 42;"}',
            ),
          ],
        ),
        const ModelReply(content: '答案现在是 42'),
      ]),
      tools: WorkspaceToolRegistry(workspace: workspace),
      approvals: broker,
      checkpoints: _NoopCheckpoints(),
      limits: const AgentLimits(maxRounds: 5),
      approvalPolicy: ToolPolicy.standard.toApprovalPolicy(),
      observer: audit,
    );

    // Resolve approvals from the launcher, like the approval UI would.
    broker.launcher = (approval) => broker.resolve(ApprovalDecision.approve);

    final result = await core.run(
      [const AgentMessage(role: MessageRole.user, content: '把答案改成 42')],
      CancelFlag(),
    );

    expect(result, isA<AgentCompleted>());
    expect((result as AgentCompleted).message, '答案现在是 42');
    expect(await workspace.readFile('app.dart'), 'int answer = 42;\n');
    // read_file auto-approved; apply_patch requested one hunk approval.
    expect(
      sink.lines.where((l) => l.contains('"event":"approval_waiting"')).length,
      1,
    );
    expect(sink.lines.where((l) => l.contains('"event":"tool_finished"')).length, 2);
  });
}

class _ScriptedModel implements StreamingModelGateway {
  _ScriptedModel(this.script);

  final List<ModelReply> script;
  int _next = 0;

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    if (_next < script.length - 1) {
      return script[_next++];
    }
    return script.last;
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String) onDelta,
  ) async =>
      complete(messages);
}

class _NoopCheckpoints implements CheckpointStore {
  @override
  Future<void> save(AgentCheckpoint checkpoint) async {}
}
