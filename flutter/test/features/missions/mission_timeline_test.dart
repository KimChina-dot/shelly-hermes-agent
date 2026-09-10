import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/app.dart';
import 'package:shelly_hermes/application/mission_coordinator.dart';
import 'package:shelly_hermes/core/events/agent_events.dart';
import 'package:shelly_hermes/core/events/event_bus.dart';
import 'package:shelly_hermes/design/theme.dart';
import 'package:shelly_hermes/domain/agent/mission.dart';
import 'package:shelly_hermes/domain/agent/mission_store.dart';
import 'package:shelly_hermes/features/missions/mission_timeline_page.dart';
import 'package:shelly_hermes/state/chat_session.dart'
    show missionBusProvider, missionCoordinatorProvider;
import 'package:shared_preferences/shared_preferences.dart';

/// PHASE 13 mission timeline read-side tests: mock SharedPreferences drive
/// a real [MissionStore]; the coordinator and bus are the real objects
/// too, so the page is exercised against the exact public API surface it
/// is allowed to read (store queries, recentActions, replayBuffer).
void main() {
  final createdAt = DateTime(2026, 9, 10, 10, 0);

  AgentMission mission(
    String id, {
    String title = '整理周报',
    MissionStatus status = MissionStatus.executing,
    List<String> plan = const [],
    List<String> taskIds = const [],
  }) =>
      AgentMission(
        id: id,
        goalId: 'goal-1',
        title: title,
        plan: plan,
        status: status,
        taskIds: taskIds,
        createdAt: createdAt,
        updatedAt: createdAt,
      );

  Future<void> seedMissions(List<AgentMission> missions) async {
    SharedPreferences.setMockInitialValues({
      MissionStore.storageKey: jsonEncode(
          [for (final entry in missions) entry.toJson()]),
    });
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: buildShellyTheme(Brightness.light),
          home: const MissionTimelinePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty store renders the friendly empty state', (tester) async {
    await seedMissions([]);
    await pumpPage(tester);

    expect(find.text('暂无使命'), findsOneWidget);
    expect(find.textContaining('在对话页发起请求后'), findsOneWidget);
    // Read-only surface: no create or write affordances anywhere.
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('list renders every stored mission newest first',
      (tester) async {
    await seedMissions([
      mission('m-1', title: '整理周报'),
      mission('m-2', title: '修复登录页样式', status: MissionStatus.completed),
      mission('m-3', title: '部署预发环境', status: MissionStatus.failed),
    ]);
    await pumpPage(tester);

    expect(find.text('整理周报'), findsOneWidget);
    expect(find.text('修复登录页样式'), findsOneWidget);
    expect(find.text('部署预发环境'), findsOneWidget);
    // Fixed, deterministic timestamp format from the store record.
    expect(find.textContaining('2026-09-10 10:00'), findsNWidgets(3));
  });

  testWidgets('statuses get distinct labels, icons and colors',
      (tester) async {
    await seedMissions([
      mission('m-exec', status: MissionStatus.executing),
      mission('m-done', status: MissionStatus.completed),
      mission('m-fail', status: MissionStatus.failed),
    ]);
    await pumpPage(tester);

    expect(find.text('执行中'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('已失败'), findsOneWidget);

    Icon pillIcon(String missionId, IconData icon) => tester.widget<Icon>(
          find.descendant(
            of: find.byKey(ValueKey('mission-status-$missionId')),
            matching: find.byIcon(icon),
          ),
        );

    // Light-theme tone colors: brand blue for executing, deep success /
    // danger tones for the terminal states (design tokens, PHASE 44).
    expect(
      pillIcon('m-exec', Icons.play_arrow_rounded).color,
      const Color(0xFF3B82F6),
    );
    expect(
      pillIcon('m-done', Icons.check_circle_outline_rounded).color,
      const Color(0xFF2E7D32),
    );
    expect(
      pillIcon('m-fail', Icons.error_outline_rounded).color,
      const Color(0xFFB3261E),
    );
  });

  testWidgets('step count takes plan length raised by bus rounds',
      (tester) async {
    final bus = AgentEventBus();
    await seedMissions([
      mission('m-plan', plan: ['第一步', '第二步', '第三步']),
      mission('m-live'), // chat-style mission: no persisted plan.
    ]);
    // Two distinct rounds observed for m-live, one for someone else —
    // only m-live's rounds may count for m-live.
    bus.publish(StepStarted(
      missionId: 'm-live',
      taskId: 't-1',
      stepIndex: 0,
      at: createdAt,
    ));
    bus.publish(StepStarted(
      missionId: 'm-live',
      taskId: 't-1',
      stepIndex: 1,
      at: createdAt,
    ));
    bus.publish(StepStarted(
      missionId: 'm-other',
      taskId: 't-2',
      stepIndex: 0,
      at: createdAt,
    ));

    await pumpPage(tester, overrides: [missionBusProvider.overrideWithValue(bus)]);

    expect(find.textContaining('3 步'), findsOneWidget); // m-plan
    expect(find.textContaining('2 步'), findsOneWidget); // m-live
  });

  testWidgets('latest logged action shows on the card and in the detail',
      (tester) async {
    final bus = AgentEventBus();
    await seedMissions([mission('m-act')]);
    final prefs = await SharedPreferences.getInstance();
    final coordinator = MissionCoordinator(
      store: MissionStore(prefs),
      bus: bus,
    );
    coordinator.recordToolCall(
      'm-act',
      toolName: 'read_file',
      ok: true,
      durationMillis: 120,
      round: 1,
    );
    coordinator.recordToolCall(
      'm-act',
      toolName: 'write_file',
      ok: false,
      durationMillis: 90,
      round: 2,
    );

    await pumpPage(tester, overrides: [
      missionBusProvider.overrideWithValue(bus),
      missionCoordinatorProvider.overrideWith((ref) async => coordinator),
    ]);

    // The card surfaces only the most recent action.
    expect(find.textContaining('最近动作 write_file · 90ms'), findsOneWidget);
    expect(find.textContaining('read_file'), findsNothing);

    // The detail timeline keeps the whole chronological log.
    await tester.tap(find.text('整理周报'));
    await tester.pumpAndSettle();
    expect(find.text('read_file'), findsOneWidget);
    expect(find.text('write_file'), findsOneWidget);
    expect(find.textContaining('成功 · 120ms'), findsOneWidget);
    expect(find.textContaining('失败 · 90ms'), findsOneWidget);
  });

  testWidgets('detail page shows plan steps, counts and timestamps',
      (tester) async {
    await seedMissions([
      mission(
        'm-detail',
        title: '发布新版本文档',
        status: MissionStatus.completed,
        plan: ['收集变更', '改写文档', '复查发布'],
        taskIds: ['t-a', 't-b'],
      ),
    ]);
    await pumpPage(tester);

    await tester.tap(find.text('发布新版本文档'));
    await tester.pumpAndSettle();

    expect(find.text('计划步骤'), findsOneWidget);
    expect(find.text('收集变更'), findsOneWidget);
    expect(find.text('改写文档'), findsOneWidget);
    expect(find.text('复查发布'), findsOneWidget);
    expect(find.textContaining('3 步 · 2 个任务'), findsOneWidget);
    expect(find.text('创建于 2026-09-10 10:00'), findsOneWidget);
    expect(find.text('更新于 2026-09-10 10:00'), findsOneWidget);
    // Read-only view: no write controls on the detail page either.
    expect(find.byType(FloatingActionButton), findsNothing);

    // Back returns to the timeline.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('发布新版本文档'), findsOneWidget);
    expect(find.text('计划步骤'), findsNothing);
  });

  testWidgets('mission tab is reachable from the app shell navigation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    // The new 使命 destination exists alongside the original five.
    final navBar = find.byType(NavigationBar);
    expect(navBar, findsOneWidget);
    await tester.tap(find.descendant(
      of: navBar,
      matching: find.text('使命'),
    ));
    await tester.pumpAndSettle();

    // Appended last, so the shell now selects index 5 and the timeline
    // page (its empty state) is the mounted body.
    expect(
      tester.widget<NavigationBar>(navBar).selectedIndex,
      5,
    );
    expect(find.text('暂无使命'), findsOneWidget);
    expect(find.text('使命'), findsWidgets);
  });
}
