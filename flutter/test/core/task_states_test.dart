import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/task_queue.dart';

const _user = AgentMessage(role: MessageRole.user, content: '任务');

class _InstantRunner implements AgentTaskRunner {
  _InstantRunner(this.result);

  final AgentResult result;

  @override
  Future<AgentResult> run(List<AgentMessage> messages,
          CancellationSignal cancellation, {AgentCheckpoint? resumeFrom}) async =>
      result;
}

class _NeverRunner implements AgentTaskRunner {
  final Completer<AgentResult> _completer = Completer<AgentResult>();

  void complete(AgentResult result) => _completer.complete(result);

  @override
  Future<AgentResult> run(List<AgentMessage> messages,
          CancellationSignal cancellation, {AgentCheckpoint? resumeFrom}) =>
      _completer.future;
}

class _ReportingRunner implements AgentTaskRunner, AgentEventReporter {
  @override
  AgentObserver? eventObserver;

  @override
  Future<AgentResult> run(List<AgentMessage> messages,
      CancellationSignal cancellation, {AgentCheckpoint? resumeFrom}) async {
    eventObserver?.onEvent(
        ApprovalWaiting(const ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}')));
    eventObserver?.onEvent(const ApprovalFinished(
        call: ToolCall(id: 't1', name: 'write_file', argumentsJson: '{}'),
        durationMillis: 1,
        decision: ApprovalDecision.approve));
    return AgentCompleted('done', _ckpt);
  }
}

const _ckpt = AgentCheckpoint(
  messages: [_user],
  round: 1,
  consumedTokens: 0,
  toolCalls: 0,
);

void main() {
  test('enqueue parks tasks beyond the concurrency cap and drains in order',
      () async {
    final gate = _NeverRunner();
    final states = <String, List<TaskState>>{};
    final coordinator = TaskCoordinator(
      agentFactory: (_) => gate,
      listener: (s) => (states[s.taskId] ??= []).add(s.state),
      maxConcurrent: 1,
    );

    coordinator.start('t1', [_user]);
    coordinator.enqueue('t2', [_user]);
    coordinator.enqueue('t3', [_user]);

    expect(coordinator.state('t1'), TaskState.running);
    expect(coordinator.state('t2'), TaskState.queued);
    expect(coordinator.state('t3'), TaskState.queued);
    expect(coordinator.pendingTaskIds(), ['t2', 't3']);

    gate.complete(AgentCompleted('ok', _ckpt));
    await Future<void>.delayed(Duration.zero);

    // t2 takes the freed slot, t3 follows; the shared gate lets both run to
    // completion immediately, so the queue drains empty in order.
    final t2States = states['t2']!;
    expect(t2States.first, TaskState.queued);
    expect(t2States, contains(TaskState.running));
    expect(t2States.last, TaskState.completed);
    expect(states['t3']!.last, TaskState.completed);
    expect(coordinator.pendingTaskIds(), isEmpty);
  });

  test('pause parks a queued task and resume returns it to the queue',
      () async {
    final gate = _NeverRunner();
    final states = <TaskState>[];
    final coordinator = TaskCoordinator(
      agentFactory: (_) => gate,
      listener: (s) {
        if (s.taskId == 't2') states.add(s.state);
      },
      maxConcurrent: 1,
    );
    coordinator.start('t1', [_user]);
    coordinator.enqueue('t2', [_user]);

    expect(coordinator.pause('t2'), isTrue);
    expect(coordinator.state('t2'), TaskState.paused);
    expect(coordinator.pause('t1'), isFalse); // running tasks keep going

    expect(coordinator.resume('t2'), isTrue);
    expect(coordinator.state('t2'), TaskState.queued);

    gate.complete(AgentCompleted('ok', _ckpt));
    await Future<void>.delayed(Duration.zero);
    expect(states, contains(TaskState.paused));
    expect(states, contains(TaskState.running));
    expect(states.last, TaskState.completed);
  });

  test('dismiss drops a parked task without ever running it', () async {
    final gate = _NeverRunner();
    var runs = 0;
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _CountingRunner(gate, () => runs++),
      listener: (_) {},
      maxConcurrent: 1,
    );
    coordinator.start('t1', [_user]);
    coordinator.enqueue('t2', [_user]);
    expect(coordinator.dismiss('t2'), isTrue);
    expect(coordinator.dismiss('t2'), isFalse);
    gate.complete(AgentCompleted('ok', _ckpt));
    await Future<void>.delayed(Duration.zero);
    expect(runs, 1);
  });

  test('a checkpoint resume reports recovering before running', () async {
    final states = <TaskState>[];
    final checkpoint = AgentCheckpoint(
      messages: const [_user],
      round: 2,
      consumedTokens: 10,
      toolCalls: 1,
    );
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _InstantRunner(AgentCompleted('resumed', _ckpt)),
      listener: (s) => states.add(s.state),
    );
    coordinator.start('r1', [_user], resumeFrom: checkpoint);
    await Future<void>.delayed(Duration.zero);
    expect(states.first, TaskState.recovering);
    expect(states.contains(TaskState.running), isTrue);
    expect(states.last, TaskState.completed);
  });

  test('approval waits surface as the unified waitingTool state', () async {
    final states = <TaskState>[];
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _ReportingRunner(),
      listener: (s) => states.add(s.state),
    );
    coordinator.start('w1', [_user]);
    await Future<void>.delayed(Duration.zero);
    expect(states, contains(TaskState.waitingTool));
    // The approval finished, so the task went back to running before done.
    final waitingIndex = states.indexOf(TaskState.waitingTool);
    expect(states[waitingIndex + 1], TaskState.running);
    expect(states.last, TaskState.completed);
  });

  test('start stays immediate without a cap, and duplicate ids are rejected',
      () async {
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _NeverRunner(),
      listener: (_) {},
    );
    expect(coordinator.start('a', [_user]), isTrue);
    expect(coordinator.start('a', [_user]), isFalse);
    expect(coordinator.enqueue('a', [_user]), isFalse);
    expect(coordinator.start('b', [_user]), isTrue);
  });
}

class _CountingRunner implements AgentTaskRunner {
  _CountingRunner(this._inner, this._onRun);

  final AgentTaskRunner _inner;
  final void Function() _onRun;

  @override
  Future<AgentResult> run(List<AgentMessage> messages,
          CancellationSignal cancellation, {AgentCheckpoint? resumeFrom}) {
    _onRun();
    return _inner.run(messages, cancellation, resumeFrom: resumeFrom);
  }
}
