import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/domain/agent/action.dart';
import 'package:shelly_hermes/domain/agent/goal.dart';
import 'package:shelly_hermes/domain/agent/mission.dart';
import 'package:shelly_hermes/domain/agent/mission_store.dart';
import 'package:shelly_hermes/domain/agent/step.dart';
import 'package:shelly_hermes/domain/agent/task.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 构造一个挂到 prefs 上的仓库;测试里反复用到。
  Future<MissionStore> newStore() async {
    final prefs = await SharedPreferences.getInstance();
    return MissionStore(prefs);
  }

  group('MissionStore CRUD', () {
    test('createMission 持久化并以最新优先排列', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      final t0 = DateTime(2026, 9, 9, 8, 0);

      final first = await store.createMission(
        goalId: 'goal-1',
        title: '整理周报',
        plan: ['收集数据', '写摘要'],
        at: t0,
      );
      final second = await store.createMission(
        goalId: 'goal-1',
        title: '部署服务',
        at: t0.add(const Duration(minutes: 1)),
      );

      expect(first.id, isNotEmpty);
      expect(first.goalId, 'goal-1');
      expect(first.title, '整理周报');
      expect(first.plan, ['收集数据', '写摘要']);
      expect(first.status, MissionStatus.planning);
      expect(first.taskIds, isEmpty);
      expect(first.createdAt, t0);
      expect(first.updatedAt, t0);

      final listed = store.listMissions();
      expect(listed.map((m) => m.id), [second.id, first.id],
          reason: '最新创建的使命应排在最前');

      // 新实例读同一份 prefs,数据仍在。
      final reloaded = await newStore();
      expect(reloaded.getById(first.id)?.title, '整理周报');
    });

    test('getById 命中与未命中', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      final mission = await store.createMission(goalId: 'g', title: 't');

      expect(store.getById(mission.id)?.id, mission.id);
      expect(store.getById('no-such-id'), isNull);
    });

    test('update 整体替换同 id 记录且保持位置;未命中返回 null', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      final a = await store.createMission(goalId: 'g', title: 'A', at: DateTime(2026, 9, 9, 8));
      final b = await store.createMission(goalId: 'g', title: 'B', at: DateTime(2026, 9, 9, 9));
      // 列表顺序为 [B, A]。

      final editedA = a.copyWith(
        title: 'A2',
        status: MissionStatus.executing,
        updatedAt: DateTime(2026, 9, 9, 10),
      );
      final updated = await store.update(editedA);
      expect(updated?.title, 'A2');
      expect(updated?.status, MissionStatus.executing);

      final listed = store.listMissions();
      expect(listed.map((m) => m.id), [b.id, a.id], reason: 'update 不应改变位置');
      expect(store.getById(a.id)?.title, 'A2');

      expect(
        await store.update(
          AgentMission(
            id: 'ghost',
            goalId: 'g',
            title: 'x',
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        ),
        isNull,
        reason: '更新不存在的使命应返回 null 且不写入',
      );
    });

    test('attachTask 追加任务 id、幂等,且未命中返回 null', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      final at = DateTime(2026, 9, 9, 12);
      final mission = await store.createMission(goalId: 'g', title: 't');

      final once = await store.attachTask(mission.id, 'task-1', at: at);
      expect(once?.taskIds, ['task-1']);
      expect(once?.updatedAt, at);

      final twice = await store.attachTask(mission.id, 'task-1', at: at);
      expect(twice?.taskIds, ['task-1'], reason: '重复挂载应被忽略(幂等)');

      expect(await store.attachTask('ghost', 'task-1'), isNull);
    });

    test('deleteAll 清空仓库', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      await store.createMission(goalId: 'g', title: 't');

      await store.deleteAll();

      expect(store.listMissions(), isEmpty);
      await store.createMission(goalId: 'g', title: 't2');
      expect(store.listMissions(), hasLength(1), reason: '清空后可继续写入');
    });
  });

  group('MissionStore 状态机守卫', () {
    test('合法迁移边全部通过', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      final at = DateTime(2026, 9, 9, 14);

      // planning → executing
      final m1 = await store.createMission(goalId: 'g', title: 'm1');
      final executing = await store.changeStatus(m1.id, MissionStatus.executing, at: at);
      expect(executing.status, MissionStatus.executing);
      expect(executing.updatedAt, at);

      // executing → waitingApproval → executing(挂起/放行环)
      final waiting = await store.changeStatus(m1.id, MissionStatus.waitingApproval);
      expect(waiting.status, MissionStatus.waitingApproval);
      final resumed = await store.changeStatus(m1.id, MissionStatus.executing);
      expect(resumed.status, MissionStatus.executing);

      // executing → completed / failed / cancelled(三条收束边)
      for (final target in [
        MissionStatus.completed,
        MissionStatus.failed,
        MissionStatus.cancelled,
      ]) {
        final m = await store.createMission(goalId: 'g', title: 'm');
        await store.changeStatus(m.id, MissionStatus.executing);
        final done = await store.changeStatus(m.id, target);
        expect(done.status, target);
      }
    });

    test('非法迁移抛 ArgumentError 且不落盘', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      final at0 = DateTime(2026, 9, 9, 8);
      final m = await store.createMission(goalId: 'g', title: 'm', at: at0);

      // planning 只能去 executing。
      for (final illegal in [
        MissionStatus.planning, // 自迁移非法
        MissionStatus.waitingApproval,
        MissionStatus.completed,
        MissionStatus.failed,
        MissionStatus.cancelled,
      ]) {
        expect(
          () => store.changeStatus(m.id, illegal),
          throwsArgumentError,
          reason: 'planning → ${illegal.name} 应被守卫拒绝',
        );
      }
      expect(store.getById(m.id)?.updatedAt, at0, reason: '被拒迁移不应刷新时间戳');

      // waitingApproval 只能回 executing。
      await store.changeStatus(m.id, MissionStatus.executing);
      await store.changeStatus(m.id, MissionStatus.waitingApproval);
      for (final illegal in [
        MissionStatus.planning,
        MissionStatus.waitingApproval,
        MissionStatus.completed,
        MissionStatus.failed,
        MissionStatus.cancelled,
      ]) {
        expect(
          () => store.changeStatus(m.id, illegal),
          throwsArgumentError,
          reason: 'waitingApproval → ${illegal.name} 应被守卫拒绝',
        );
      }

      // 终态不可迁出。
      await store.changeStatus(m.id, MissionStatus.executing);
      await store.changeStatus(m.id, MissionStatus.cancelled);
      for (final to in MissionStatus.values) {
        expect(
          () => store.changeStatus(m.id, to),
          throwsArgumentError,
          reason: 'cancelled → ${to.name} 应被守卫拒绝(终态不可迁出)',
        );
      }
    });

    test('isLegalTransition 覆盖全部迁移矩阵', () {
      // 显式合法边。
      final legal = {
        (MissionStatus.planning, MissionStatus.executing),
        (MissionStatus.executing, MissionStatus.waitingApproval),
        (MissionStatus.executing, MissionStatus.completed),
        (MissionStatus.executing, MissionStatus.failed),
        (MissionStatus.executing, MissionStatus.cancelled),
        (MissionStatus.waitingApproval, MissionStatus.executing),
      };
      for (final from in MissionStatus.values) {
        for (final to in MissionStatus.values) {
          final result = MissionStore.isLegalTransition(from, to);
          if (legal.contains((from, to))) {
            expect(result, isTrue, reason: '$from → $to 应合法');
          } else {
            expect(result, isFalse, reason: '$from → $to 应非法');
          }
        }
      }
    });

    test('对不存在的使命 changeStatus 抛 ArgumentError', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();
      expect(
        () => store.changeStatus('ghost', MissionStatus.executing),
        throwsArgumentError,
      );
    });
  });

  group('MissionStore 容量与容错', () {
    test('超过 maxMissions 时最旧的使命被丢弃', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await newStore();

      AgentMission? first;
      for (var i = 0; i < MissionStore.maxMissions + 5; i++) {
        final mission = await store.createMission(
          goalId: 'g',
          title: 'm-$i',
          at: DateTime(2026, 9, 9).add(Duration(minutes: i)),
        );
        first ??= mission;
      }

      final listed = store.listMissions();
      expect(listed, hasLength(MissionStore.maxMissions));
      expect(listed.any((m) => m.id == first!.id), isFalse,
          reason: '最旧的使命应被挤出容量上限');
      expect(listed.first.title, 'm-${MissionStore.maxMissions + 4}',
          reason: '最新创建的使命应保留在最前');
    });

    test('损坏载荷读回为空仓库且可恢复写入', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(MissionStore.storageKey, 'not-json{');

      final store = MissionStore(prefs);
      expect(store.listMissions(), isEmpty, reason: '非法 JSON 应静默回退为空');
      expect(store.getById('x'), isNull);

      // 仓库恢复:新使命能正常落在被清空的载荷之上。
      await store.createMission(goalId: 'g', title: 't');
      expect(store.listMissions(), hasLength(1));
    });

    test('顶层不是数组的载荷同样回退为空', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(MissionStore.storageKey, '{"oops": true}');

      final store = MissionStore(prefs);
      expect(store.listMissions(), isEmpty);
    });

    test('单条记录形状非法时逐条跳过,不影响其余记录', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final good = AgentMission(
        id: 'good-1',
        goalId: 'g',
        title: '好记录',
        createdAt: DateTime(2026, 9, 9),
        updatedAt: DateTime(2026, 9, 9),
      );
      await prefs.setString(
        MissionStore.storageKey,
        jsonEncode([
          'a-bare-string',
          good.toJson(),
          {'not': 'a mission, but survives lenient decode'},
        ]),
      );

      final store = MissionStore(prefs);
      final listed = store.listMissions();
      expect(listed, hasLength(2), reason: '非 Map 条目被跳过,Map 条目宽松解码存活');
      expect(listed.any((m) => m.id == 'good-1'), isTrue);
    });
  });

  group('域模型 JSON 往返与值语义', () {
    test('AgentGoal JSON 往返 + copyWith + 相等性', () {
      final at = DateTime(2026, 9, 9, 8);
      final goal = AgentGoal(
        id: 'goal-1',
        title: '发布 v3',
        description: '完成三阶段迁移',
        status: GoalStatus.active,
        createdAt: at,
        updatedAt: at,
        projectId: 'proj-1',
      );

      final roundTrip = AgentGoal.fromJson(goal.toJson());
      expect(roundTrip, equals(goal));
      expect(roundTrip.hashCode, goal.hashCode);
      expect(roundTrip.projectId, 'proj-1');

      // projectId 为 null 时省键,读回仍是 null。
      final bare = AgentGoal(id: 'g2', title: 't', createdAt: at, updatedAt: at);
      expect(AgentGoal.fromJson(bare.toJson()), equals(bare));
      expect(AgentGoal.fromJson(bare.toJson()).projectId, isNull);

      // 未知状态名与缺失字段宽松兜底。
      final lenient = AgentGoal.fromJson({
        'id': 'g3',
        'status': 'no-such-status',
      });
      expect(lenient.status, GoalStatus.active);
      expect(lenient.title, '');

      // copyWith 覆盖与保留。
      final copied = goal.copyWith(status: GoalStatus.completed);
      expect(copied.status, GoalStatus.completed);
      expect(copied.title, '发布 v3');
      expect(goal == copied, isFalse, reason: '改了状态后应不相等');
      expect(goal == AgentGoal.fromJson(goal.toJson()), isTrue);
    });

    test('AgentMission JSON 往返 + copyWith 列表浅拷贝', () {
      final at = DateTime(2026, 9, 9, 9);
      final mission = AgentMission(
        id: 'mission-1',
        goalId: 'goal-1',
        title: '部署 v3',
        plan: ['构建', '冒烟', '发布'],
        status: MissionStatus.executing,
        taskIds: ['task-1', 'task-2'],
        createdAt: at,
        updatedAt: at,
      );

      final roundTrip = AgentMission.fromJson(mission.toJson());
      expect(roundTrip, equals(mission));
      expect(roundTrip.hashCode, mission.hashCode);

      // 缺省字段宽松解码。
      final lenient = AgentMission.fromJson({'id': 'm2'});
      expect(lenient.plan, isEmpty);
      expect(lenient.taskIds, isEmpty);
      expect(lenient.status, MissionStatus.planning);

      // 非字符串列表项被过滤。
      expect(
        AgentMission.fromJson({
          'plan': ['a', 1, null, 'b'],
          'taskIds': ['t', {}, 'u'],
        }).plan,
        ['a', 'b'],
      );

      // copyWith:显式传入的列表替换,未传的深/浅拷贝防共享突变。
      final copied = mission.copyWith(status: MissionStatus.failed);
      final mutated = copied.plan..add('别扩散到我');
      expect(mission.plan, ['构建', '冒烟', '发布'], reason: '原对象不应被共享列表突变');
      expect(mutated, isNot(same(mission.plan)));

      expect(
        mission.copyWith(plan: ['新计划']).plan,
        ['新计划'],
      );
    });

    test('AgentTaskRecord JSON 往返 + copyWith', () {
      final at = DateTime(2026, 9, 9, 10);
      final task = AgentTaskRecord(
        id: 'task-1',
        missionId: 'mission-1',
        title: '跑冒烟测试',
        status: AgentTaskStatus.completed,
        result: '全部通过',
        createdAt: at,
        updatedAt: at,
      );

      final roundTrip = AgentTaskRecord.fromJson(task.toJson());
      expect(roundTrip, equals(task));
      expect(roundTrip.hashCode, task.hashCode);

      // result 为 null 时省键,读回仍是 null。
      final bare = AgentTaskRecord(
        id: 'task-2',
        missionId: 'mission-1',
        title: 't',
        createdAt: at,
        updatedAt: at,
      );
      final bareTrip = AgentTaskRecord.fromJson(bare.toJson());
      expect(bareTrip, equals(bare));
      expect(bareTrip.result, isNull);

      // 未知状态名回退 pending。
      expect(
        AgentTaskRecord.fromJson({'id': 't3', 'status': 'bogus'}).status,
        AgentTaskStatus.pending,
      );

      final copied = task.copyWith(status: AgentTaskStatus.skipped, result: null);
      expect(copied.status, AgentTaskStatus.skipped);
      expect(task == copied, isFalse);
    });

    test('AgentStep JSON 往返 + copyWith', () {
      final step = AgentStep(
        index: 2,
        description: '校验产物',
        status: AgentStepStatus.running,
      );

      final roundTrip = AgentStep.fromJson(step.toJson());
      expect(roundTrip, equals(step));
      expect(roundTrip.hashCode, step.hashCode);

      // 缺失字段宽松兜底。
      final lenient = AgentStep.fromJson({});
      expect(lenient.index, 0);
      expect(lenient.description, '');
      expect(lenient.status, AgentStepStatus.pending);

      final copied = step.copyWith(status: AgentStepStatus.done);
      expect(copied.status, AgentStepStatus.done);
      expect(copied.index, 2);
      expect(step == copied, isFalse);
    });

    test('AgentAction JSON 往返 + copyWith', () {
      final at = DateTime(2026, 9, 9, 11);
      final action = AgentAction(
        id: 'action-1',
        type: 'web.search',
        inputSummary: 'query=v3 迁移',
        outputSummary: '5 条结果',
        ok: true,
        durationMillis: 320,
        at: at,
      );

      final roundTrip = AgentAction.fromJson(action.toJson());
      expect(roundTrip, equals(action));
      expect(roundTrip.hashCode, action.hashCode);
      expect(AgentAction.fromJson(action.toJson()).toString(),
          contains('web.search'));

      // 非法类型字段兜底。
      final lenient = AgentAction.fromJson({
        'ok': 'yes',
        'durationMillis': 'fast',
      });
      expect(lenient.ok, isFalse);
      expect(lenient.durationMillis, 0);
      expect(lenient.type, '');

      final copied =
          action.copyWith(ok: false, outputSummary: '超时');
      expect(copied.ok, isFalse);
      expect(copied.inputSummary, 'query=v3 迁移');
      expect(action == copied, isFalse);
    });
  });
}
