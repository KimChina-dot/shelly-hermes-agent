import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/events/agent_events.dart';
import 'package:shelly_hermes/core/events/event_bus.dart';

void main() {
  final at = DateTime(2026, 1, 2, 3, 4, 5);

  MissionCreated mission(String id, [String title = 'find the grail']) =>
      MissionCreated(missionId: id, title: title, at: at);

  TaskStarted taskStarted(String missionId, String taskId) => TaskStarted(
        missionId: missionId,
        taskId: taskId,
        title: 'task $taskId',
        at: at,
      );

  group('MissionEvent value semantics', () {
    test('equality and hashCode', () {
      final a = mission('m1');
      final b = mission('m1');
      final c = mission('m2');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));

      final plan1 = PlanCreated(missionId: 'm1', steps: ['a', 'b'], at: at);
      final plan2 = PlanCreated(missionId: 'm1', steps: ['a', 'b'], at: at);
      final plan3 = PlanCreated(missionId: 'm1', steps: ['a'], at: at);
      expect(plan1, equals(plan2));
      expect(plan1.hashCode, plan2.hashCode);
      expect(plan1, isNot(equals(plan3)));

      expect(taskStarted('m1', 't1'), equals(taskStarted('m1', 't1')));
      expect(taskStarted('m1', 't1'), isNot(equals(taskStarted('m1', 't2'))));

      expect(
        TaskFailed(missionId: 'm1', taskId: 't1', error: 'boom', at: at),
        equals(
          TaskFailed(missionId: 'm1', taskId: 't1', error: 'boom', at: at),
        ),
      );
      expect(
        StepStarted(missionId: 'm1', taskId: 't1', stepIndex: 3, at: at),
        equals(
          StepStarted(missionId: 'm1', taskId: 't1', stepIndex: 3, at: at),
        ),
      );
      for (final event in [
        MissionCompleted(missionId: 'm1', at: at),
        MissionFailed(missionId: 'm1', error: 'boom', at: at),
        MissionCancelled(missionId: 'm1', at: at),
        PlanUpdated(missionId: 'm1', steps: const ['a'], at: at),
        TaskCompleted(missionId: 'm1', taskId: 't1', at: at),
      ]) {
        expect(event, equals(event));
      }
    });

    test('different event types are never equal', () {
      expect(
        MissionCompleted(missionId: 'm1', at: at),
        isNot(equals(MissionCancelled(missionId: 'm1', at: at))),
      );
      expect(
        taskStarted('m1', 't1'),
        isNot(equals(TaskCompleted(missionId: 'm1', taskId: 't1', at: at))),
      );
    });

    test('toString carries type and payload', () {
      expect(mission('m1').toString(), contains('MissionCreated'));
      expect(mission('m1').toString(), contains('m1'));
      expect(taskStarted('m1', 't1').toString(), contains('TaskStarted'));
      expect(
        PlanCreated(missionId: 'm1', steps: ['a', 'b'], at: at).toString(),
        contains('PlanCreated'),
      );
    });
  });

  group('AgentEventBus broadcast', () {
    test('publishes to multiple listeners', () {
      final bus = AgentEventBus();
      final a = <MissionEvent>[];
      final b = <MissionEvent>[];
      bus.subscribe().listen(a.add);
      bus.subscribe().listen(b.add);

      final event = mission('m1');
      bus.publish(event);

      expect(a, [event]);
      expect(b, [event]);
      bus.dispose();
    });

    test('each listener receives later events independently', () {
      final bus = AgentEventBus();
      final a = <MissionEvent>[];
      final b = <MissionEvent>[];
      bus.subscribe().listen(a.add);

      bus.publish(mission('m1'));
      bus.subscribe().listen(b.add); // subscribes mid-stream: replays m1
      bus.publish(mission('m2'));

      expect(a.map((e) => e.missionId), ['m1', 'm2']);
      expect(b.map((e) => e.missionId), ['m1', 'm2'],
          reason: 'replay hands over the missed event, then live delivery');
      bus.dispose();
    });
  });

  group('AgentEventBus filter', () {
    test('live events are filtered per listener', () {
      final bus = AgentEventBus();
      final completions = <MissionEvent>[];
      final everything = <MissionEvent>[];
      bus
          .subscribe(filter: (e) => e is TaskCompleted)
          .listen(completions.add);
      bus.subscribe().listen(everything.add);

      bus.publish(mission('m1'));
      bus.publish(taskStarted('m1', 't1'));
      bus.publish(TaskCompleted(missionId: 'm1', taskId: 't1', at: at));
      bus.publish(MissionCompleted(missionId: 'm1', at: at));

      expect(completions.map((e) => e.runtimeType), [TaskCompleted]);
      expect(everything, hasLength(4));
      bus.dispose();
    });

    test('replay respects the filter too', () {
      final bus = AgentEventBus();
      bus.publish(taskStarted('m1', 't1'));
      bus.publish(TaskCompleted(missionId: 'm1', taskId: 't1', at: at));

      final seen = <MissionEvent>[];
      bus.subscribe(filter: (e) => e is TaskCompleted).listen(seen.add);

      expect(seen.map((e) => e.runtimeType), [TaskCompleted]);
      bus.dispose();
    });
  });

  group('AgentEventBus replay buffer', () {
    test('new subscribers receive the buffer first, then live events', () {
      final bus = AgentEventBus();
      final first = mission('m1');
      final second = mission('m2');
      bus.publish(first);
      bus.publish(second);

      final lateListener = <MissionEvent>[];
      bus.subscribe().listen(lateListener.add);

      final third = mission('m3');
      bus.publish(third);

      expect(lateListener, [first, second, third]);
      bus.dispose();
    });

    test('replay buffer keeps the last N events', () {
      final bus = AgentEventBus(replayBufferSize: 2);
      bus.publish(mission('m1'));
      bus.publish(mission('m2'));
      bus.publish(mission('m3'));

      expect(bus.replayBuffer.map((e) => e.missionId), ['m2', 'm3']);

      final seen = <MissionEvent>[];
      bus.subscribe().listen(seen.add);
      expect(seen.map((e) => e.missionId), ['m2', 'm3']);
      bus.dispose();
    });

    test('default capacity is 50', () {
      final bus = AgentEventBus();
      for (var i = 0; i < 60; i++) {
        bus.publish(mission('m$i'));
      }
      expect(bus.replayBuffer, hasLength(50));
      expect(bus.replayBuffer.first.missionId, 'm10');
      expect(bus.replayBuffer.last.missionId, 'm59');
      bus.dispose();
    });

    test('replayBuffer is unmodifiable', () {
      final bus = AgentEventBus();
      bus.publish(mission('m1'));
      expect(
        () => bus.replayBuffer.add(mission('m2')),
        throwsUnsupportedError,
      );
      bus.dispose();
    });
  });

  group('AgentEventBus error isolation', () {
    test('a throwing listener does not break other listeners nor the bus',
        () {
      final errors = <Object>[];
      final bus = AgentEventBus(
        onListenerError: (event, error) => errors.add(error),
      );
      final broken = <MissionEvent>[];
      final healthy = <MissionEvent>[];

      void brokenHandler(MissionEvent event) {
        if (event.missionId == 'm1') {
          throw StateError('listener exploded');
        }
        broken.add(event);
      }

      bus.subscribe().listen(brokenHandler);
      bus.subscribe().listen(healthy.add);

      final e1 = mission('m1');
      final e2 = mission('m2');
      final e3 = mission('m3');
      bus.publish(e1); // broken listener throws here
      bus.publish(e2); // both must still receive this
      bus.publish(e3);

      expect(errors, [isA<StateError>()]);
      expect(broken, [e2, e3], reason: 'broken listener stays alive');
      expect(healthy, [e1, e2, e3]);

      // The bus itself is still fully functional.
      expect(bus.replayBuffer, [e1, e2, e3]);
      final fresh = <MissionEvent>[];
      bus.subscribe().listen(fresh.add);
      expect(fresh, [e1, e2, e3]);
      bus.dispose();
    });

    test('every event from a throwing listener is reported', () {
      final reported = <MissionEvent>[];
      final bus = AgentEventBus(
        onListenerError: (event, error) => reported.add(event),
      );
      bus.subscribe().listen((_) => throw StateError('nope'));

      final e1 = mission('m1');
      final e2 = mission('m2');
      bus.publish(e1);
      bus.publish(e2);

      expect(reported, [e1, e2]);
      bus.dispose();
    });

    test('a throwing filter does not break the bus or other listeners', () {
      final errors = <Object>[];
      final bus = AgentEventBus(
        onListenerError: (event, error) => errors.add(error),
      );
      final filtered = <MissionEvent>[];
      final healthy = <MissionEvent>[];
      var calls = 0;

      bus
          .subscribe(
            filter: (event) {
              calls++;
              if (calls == 1) throw StateError('filter exploded');
              return true;
            },
          )
          .listen(filtered.add);
      bus.subscribe().listen(healthy.add);

      final e1 = mission('m1');
      final e2 = mission('m2');
      bus.publish(e1); // filter throws here
      bus.publish(e2); // filter recovers and passes

      expect(errors, [isA<StateError>()]);
      expect(filtered, [e2], reason: 'filter stays alive after throwing');
      expect(healthy, [e1, e2]);
      expect(bus.replayBuffer, [e1, e2]);
      bus.dispose();
    });

    test('no unhandled async errors escape to the zone', () async {
      final bus = AgentEventBus();
      bus.subscribe().listen((_) => throw StateError('zone escape'));
      bus.publish(mission('m1'));
      // Give any (incorrectly) unhandled async error a chance to surface —
      // the test zone fails on unhandled errors, so reaching this line
      // means delivery was properly guarded.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      bus.dispose();
    });
  });

  group('AgentEventBus dispose', () {
    test('dispose closes subscriber streams', () async {
      final bus = AgentEventBus();
      var done = false;
      final received = <MissionEvent>[];
      bus.subscribe().listen(received.add, onDone: () => done = true);

      bus.publish(mission('m1'));
      await bus.dispose();

      expect(done, isTrue);
      expect(received, hasLength(1));
    });

    test('publish after dispose is a safe no-op', () async {
      final bus = AgentEventBus();
      bus.publish(mission('m1'));
      await bus.dispose();

      expect(
        () => bus.publish(mission('m2')),
        returnsNormally,
      );
      expect(bus.replayBuffer, hasLength(1));
      expect(bus.isDisposed, isTrue);
    });

    test('dispose is idempotent', () async {
      final bus = AgentEventBus();
      await bus.dispose();
      await expectLater(bus.dispose(), completes);
    });

    test('subscriber still receives its buffered replay before closing',
        () async {
      final bus = AgentEventBus();
      bus.publish(mission('m1'));
      final seen = <MissionEvent>[];
      var done = false;

      bus.subscribe().listen(seen.add, onDone: () => done = true);
      await bus.dispose();

      expect(seen.map((e) => e.missionId), ['m1']);
      expect(done, isTrue);
    });
  });

  group('AgentEventBus pause/cancel', () {
    test('pause holds back delivery until resume', () async {
      final bus = AgentEventBus();
      final seen = <MissionEvent>[];
      final subscription = bus.subscribe().listen(seen.add);

      subscription.pause();
      bus.publish(mission('m1'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);

      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      await subscription.cancel();
      await bus.dispose();
    });

    test('cancel stops delivery', () async {
      final bus = AgentEventBus();
      final seen = <MissionEvent>[];
      final subscription = bus.subscribe().listen(seen.add);

      await subscription.cancel();
      bus.publish(mission('m1'));
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
      await bus.dispose();
    });
  });
}
