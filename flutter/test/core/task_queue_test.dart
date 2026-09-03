import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/task_queue.dart';

class _StubRunner implements AgentTaskRunner {
  _StubRunner(this.result);

  final AgentResult result;
  CancellationSignal? lastCancellation;

  @override
  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    lastCancellation = cancellation;
    return result;
  }
}

AgentMessage userMsg(String text) => AgentMessage(role: MessageRole.user, content: text);

void main() {
  test('start runs the task to completion and publishes state transitions',
      () async {
    final statuses = <TaskStatus>[];
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _StubRunner(
        const AgentCompleted('done', AgentCheckpoint(messages: [], round: 1, consumedTokens: 1, toolCalls: 0)),
      ),
      listener: statuses.add,
    );

    expect(coordinator.start('task-1', [userMsg('hi')]), isTrue);
    await pumpEventQueue();

    expect(statuses.map((s) => s.state).toList(), [
      TaskState.starting,
      TaskState.running,
      TaskState.completed,
    ]);
    expect(coordinator.state('task-1'), isNull);
    expect(coordinator.activeTaskIds(), isEmpty);
  });

  test('start rejects a duplicate active task id', () async {
    // Runner awaits a never-completing future until we let it finish.
    var releaseRunner = Completer<void>();
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _BlockingRunner(releaseRunner.future),
      listener: (_) {},
    );

    expect(coordinator.start('t', [userMsg('hi')]), isTrue);
    expect(coordinator.start('t', [userMsg('hi')]), isFalse);

    releaseRunner.complete();
    await pumpEventQueue();
    expect(coordinator.activeTaskIds(), isEmpty);
  });

  test('stop signals cancellation and maps completed stop to stopped state',
      () async {
    final statuses = <TaskStatus>[];
    final flags = <CancellationSignal?>[];
    var release = Completer<void>();
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _BlockingCapturingRunner(release.future, flags),
      listener: statuses.add,
    );

    coordinator.start('t', [userMsg('hi')]);
    await pumpEventQueue();
    expect(coordinator.stop('t'), isTrue);
    // Second signal is ignored: already cancelled.
    expect(coordinator.stop('t'), isFalse);
    release.complete();
    await pumpEventQueue();

    expect(flags.single!.isCancelled, isTrue);
    expect(statuses.map((s) => s.state), contains(TaskState.stopping));
    expect(statuses.last.state, TaskState.stopped);
  });

  test('stop on unknown task returns false', () async {
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _StubRunner(const AgentStopped('x', AgentCheckpoint(messages: [], round: 0, consumedTokens: 0, toolCalls: 0))),
      listener: (_) {},
    );

    expect(coordinator.stop('missing'), isFalse);
    expect(coordinator.cancel('missing'), isFalse);
  });

  test('failing runner publishes failed state with the error', () async {
    final statuses = <TaskStatus>[];
    final coordinator = TaskCoordinator(
      agentFactory: (_) => _ExplodingRunner(),
      listener: statuses.add,
    );

    coordinator.start('t', [userMsg('hi')]);
    await pumpEventQueue();

    expect(statuses.last.state, TaskState.failed);
    expect(statuses.last.error, isNotNull);
  });
}

class _BlockingRunner implements AgentTaskRunner {
  _BlockingRunner(this.future);

  final Future<void> future;

  @override
  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    await future;
    return const AgentStopped(
      'cancelled',
      AgentCheckpoint(messages: [], round: 0, consumedTokens: 0, toolCalls: 0),
    );
  }
}

class _BlockingCapturingRunner implements AgentTaskRunner {
  _BlockingCapturingRunner(this.future, this.sink);

  final Future<void> future;
  final List<CancellationSignal?> sink;

  @override
  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    sink.add(cancellation);
    await future;
    return const AgentStopped(
      'cancelled',
      AgentCheckpoint(messages: [], round: 0, consumedTokens: 0, toolCalls: 0),
    );
  }
}

class _ExplodingRunner implements AgentTaskRunner {
  @override
  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    throw StateError('model gateway unreachable');
  }
}
