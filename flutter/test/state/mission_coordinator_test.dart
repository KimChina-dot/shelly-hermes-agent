/// PHASE 2 mission bridge tests.
///
/// Covers [MissionCoordinator] against the REAL [MissionStore]
/// (SharedPreferences mock backend) and the REAL [AgentEventBus] — no
/// fakes — plus the end-to-end wiring through the chat session's task
/// runner via the `chatGatewayOverrideProvider` pattern: a full chat round
/// must create a mission, record one step per model round, and settle the
/// mission as completed; a scripted gateway failure must settle it as
/// failed; a missing prefs backend must degrade to a no-op.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/application/mission_coordinator.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/events/agent_events.dart';
import 'package:shelly_hermes/core/events/event_bus.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/domain/agent/mission.dart';
import 'package:shelly_hermes/domain/agent/mission_store.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Gateway stub that replays canned replies and records every request
/// (same pattern as steering_test.dart). When the script is exhausted it
/// throws, which fails the task through the real engine error path.
class _ScriptedGateway implements StreamingModelGateway {
  _ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  final List<List<AgentMessage>> seen = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seen.add(List.of(messages));
    if (replies.isNotEmpty) return replies.removeAt(0);
    throw StateError('script exhausted');
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    final reply = await complete(messages);
    if (reply.content.isNotEmpty) onDelta(reply.content);
    return reply;
  }
}

/// Collects every event the bus delivers, newest last.
class _EventCollector {
  _EventCollector(AgentEventBus bus) {
    bus.subscribe().listen(events.add);
  }

  final List<MissionEvent> events = [];

  /// Event types seen so far (repeats included).
  Iterable<Type> get types => events.map((e) => e.runtimeType);

  MissionCreated? get created => events.whereType<MissionCreated>().firstOrNull;

  List<StepStarted> get steps => events.whereType<StepStarted>().toList();
}

/// Lets pending coordinator futures (mission creation chains) run to
/// completion before assertions.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Waits until [predicate] holds (mission bookkeeping is async), failing
/// after ~2s.
Future<void> _waitUntil(bool Function() predicate, String description) async {
  for (var i = 0; i < 200; i += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not reached: $description');
}

/// Waits until the chat task settles (idle), failing after ~10s.
Future<void> _waitForIdle(ProviderContainer container) async {
  for (var i = 0; i < 500; i += 1) {
    if (!container.read(chatSessionProvider).isBusy) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('chat task did not return to idle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MissionCoordinator', () {
    late MissionStore store;
    late AgentEventBus bus;
    late _EventCollector collector;
    late MissionCoordinator coordinator;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = MissionStore(await SharedPreferences.getInstance());
      bus = AgentEventBus();
      collector = _EventCollector(bus);
      coordinator = MissionCoordinator(store: store, bus: bus);
    });

    test('startForConversation creates an executing mission and publishes '
        'MissionCreated', () async {
      final handle = coordinator.startForConversation('conv-1', '帮我整理桌面文件');
      expect(handle, isNot(MissionCoordinator.noMission));

      await _settle();
      // Store side: exactly one mission, status executing, goal wired to
      // the conversation.
      final missions = store.listMissions();
      expect(missions, hasLength(1));
      expect(missions.single.status, MissionStatus.executing);
      expect(missions.single.goalId, 'conv-1');
      expect(missions.single.title, '帮我整理桌面文件');

      // Bus side: MissionCreated carries the store mission id and title.
      await _waitUntil(() => collector.created != null, 'MissionCreated');
      expect(collector.created!.missionId, missions.single.id);
      expect(collector.created!.title, '帮我整理桌面文件');
    });

    test('title is the first 30 chars of the user text', () async {
      coordinator.startForConversation('conv-1', 'a' * 50);
      await _settle();
      expect(store.listMissions().single.title, 'a' * 30);
    });

    test('status transitions executing → completed, publishing '
        'MissionCompleted', () async {
      final handle = coordinator.startForConversation('conv-1', '任务');
      await _settle();
      final id = store.listMissions().single.id;

      coordinator.complete(handle);
      await _waitUntil(
        () => collector.types.contains(MissionCompleted),
        'MissionCompleted',
      );
      expect(store.getById(id)!.status, MissionStatus.completed);
      expect(collector.types, [MissionCreated, MissionCompleted]);
    });

    test('status transitions executing → failed with error, publishing '
        'MissionFailed', () async {
      final handle = coordinator.startForConversation('conv-1', '任务');
      await _settle();
      final id = store.listMissions().single.id;

      coordinator.complete(handle, error: 'boom');
      await _waitUntil(
        () => collector.types.contains(MissionFailed),
        'MissionFailed',
      );
      expect(store.getById(id)!.status, MissionStatus.failed);
      expect(collector.events.whereType<MissionFailed>().single.error, 'boom');
    });

    test('recordRound publishes one StepStarted per round', () async {
      final handle = coordinator.startForConversation('conv-1', '任务');
      await _settle();
      final id = store.listMissions().single.id;

      coordinator.recordRound(handle, round: 1, taskId: 'task-1');
      coordinator.recordRound(handle, round: 2, taskId: 'task-1');
      coordinator.recordRound(handle, round: 3, taskId: 'task-1');

      await _waitUntil(() => collector.steps.length == 3, '3 steps');
      expect(
        [for (final step in collector.steps) step.stepIndex],
        [1, 2, 3],
      );
      expect(collector.steps.every((s) => s.missionId == id), isTrue);
      expect(collector.steps.every((s) => s.taskId == 'task-1'), isTrue);
    });

    test('recordToolCall keeps a capped coordinator-local action log and '
        'publishes nothing', () async {
      final handle = coordinator.startForConversation('conv-1', '任务');
      await _settle();
      final before = collector.events.length;

      coordinator.recordToolCall(
        handle,
        toolName: 'write_file',
        ok: true,
        durationMillis: 12,
        round: 1,
      );
      expect(coordinator.recentActions, hasLength(1));
      expect(coordinator.recentActions.single.toolName, 'write_file');
      expect(coordinator.recentActions.single.ok, isTrue);
      expect(coordinator.recentActions.single.round, 1);
      expect(collector.events.length, before); // no extra events published

      for (var i = 0; i < MissionCoordinator.maxLocalActions + 10; i += 1) {
        coordinator.recordToolCall(
          handle,
          toolName: 'tool-$i',
          ok: false,
          durationMillis: i,
          round: 1,
        );
      }
      expect(coordinator.recentActions.length,
          MissionCoordinator.maxLocalActions);
      expect(coordinator.recentActions.last.toolName,
          'tool-${MissionCoordinator.maxLocalActions + 9}');
    });

    test('unknown handle / empty missionId degrade to no-ops without '
        'throwing', () async {
      // Unknown handle: treated as a direct store id — the store's
      // ArgumentError for a missing mission is swallowed.
      expect(() => coordinator.complete('no-such-mission'), returnsNormally);
      expect(
        () => coordinator.recordRound('no-such-mission', round: 1),
        returnsNormally,
      );
      // Sentinel id: skipped entirely.
      expect(
        () => coordinator.complete(MissionCoordinator.noMission),
        returnsNormally,
      );
      expect(() => coordinator.recordRound('', round: 1), returnsNormally);
      await _settle();
      expect(collector.events, isEmpty);
      expect(store.listMissions(), isEmpty);
    });

    test('complete() racing creation still settles the mission completed', () async {
      final handle = coordinator.startForConversation('conv-1', '快任务');
      coordinator.complete(handle); // no _settle() in between on purpose
      await _settle();
      await _settle();
      // The coordinator sequences complete() after the creation chain, so
      // the mission (if created) never lingers in planning/executing.
      expect(store.listMissions().single.status, MissionStatus.completed);
    });
  });

  group('chat session ↔ mission bridge (end-to-end)', () {
    test('a full chat round creates and completes a mission with one step '
        'per round', () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _ScriptedGateway([const ModelReply(content: '第一答')]);
      final bus = AgentEventBus();
      final collector = _EventCollector(bus);
      final container = ProviderContainer(overrides: [
        chatGatewayOverrideProvider.overrideWith((ref) => gateway),
        missionBusProvider.overrideWithValue(bus),
      ]);
      addTearDown(container.dispose);

      final store = SettingsStore(await SharedPreferences.getInstance());
      final controller = container.read(chatSessionProvider.notifier);
      controller.attach(store);

      await controller.send('你好');
      await _waitForIdle(container);

      // Store side: exactly one executing → completed mission.
      final missionStore = MissionStore(await SharedPreferences.getInstance());
      await _waitUntil(
        () => missionStore.listMissions().singleOrNull?.status ==
            MissionStatus.completed,
        'mission completed',
      );
      final missions = missionStore.listMissions();
      expect(missions, hasLength(1));
      expect(missions.single.status, MissionStatus.completed);
      expect(missions.single.title, contains('你好'));

      // Bus side: created → one step per model round → completed.
      await _waitUntil(
        () => collector.types.contains(MissionCompleted),
        'MissionCompleted',
      );
      expect(collector.created, isNotNull);
      expect(collector.created!.missionId, missions.single.id);
      expect(collector.created!.title, missions.single.title);
      expect(collector.steps, hasLength(1)); // one model round
      expect(collector.steps.single.stepIndex, 1);
      expect(
        collector.types,
        [MissionCreated, StepStarted, MissionCompleted],
      );
    });

    test('a gateway failure settles the mission as failed', () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _ScriptedGateway(const []); // throws immediately
      final bus = AgentEventBus();
      final collector = _EventCollector(bus);
      final container = ProviderContainer(overrides: [
        chatGatewayOverrideProvider.overrideWith((ref) => gateway),
        missionBusProvider.overrideWithValue(bus),
      ]);
      addTearDown(container.dispose);

      final store = SettingsStore(await SharedPreferences.getInstance());
      final controller = container.read(chatSessionProvider.notifier);
      controller.attach(store);

      await controller.send('触发失败');
      await _waitForIdle(container);

      final missionStore = MissionStore(await SharedPreferences.getInstance());
      await _waitUntil(
        () => missionStore.listMissions().singleOrNull?.status ==
            MissionStatus.failed,
        'mission failed',
      );
      expect(missionStore.listMissions(), hasLength(1));
      await _waitUntil(
        () => collector.types.contains(MissionFailed),
        'MissionFailed event',
      );
      expect(
        collector.events.whereType<MissionFailed>().single.error,
        isNotEmpty,
      );
    });

    test('a missing prefs backend degrades to no-op without breaking the '
        'chat', () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _ScriptedGateway([const ModelReply(content: '降级回答')]);
      final bus = AgentEventBus();
      final collector = _EventCollector(bus);
      final container = ProviderContainer(overrides: [
        chatGatewayOverrideProvider.overrideWith((ref) => gateway),
        missionBusProvider.overrideWithValue(bus),
        // prefs resolve to null → missionStoreProvider yields null →
        // missionCoordinatorProvider yields null → bridge stays off.
        missionStoreProvider.overrideWith((ref) async => null),
      ]);
      addTearDown(container.dispose);

      final store = SettingsStore(await SharedPreferences.getInstance());
      final controller = container.read(chatSessionProvider.notifier);
      controller.attach(store);

      await controller.send('降级对话');
      await _waitForIdle(container);

      // The chat ran exactly as before: the assistant reply streamed in.
      final entries = container.read(chatSessionProvider).entries;
      expect(
        entries.whereType<AssistantEntry>().map((e) => e.text),
        contains('降级回答'),
      );
      // And no mission bookkeeping happened anywhere.
      expect(collector.events, isEmpty);
    });
  });
}
