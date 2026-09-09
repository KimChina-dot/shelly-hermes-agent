import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'mission.dart';

/// v3 Agent 域存储:使命仓库(MissionStore)。
///
/// 持久化约定与 MemoryStore 一致:单个 SharedPreferences 字符串键存一个
/// JSON 数组、最新优先、容量封顶、载荷损坏时静默回退为空仓库(遵循全库
/// “schema 损坏清空而不是崩溃”的容错模式,见 docs/audit/DATA_MODEL_MAP.md §0)。
///
/// 状态机守卫:使命生命周期只允许以下迁移边,其余一律抛
/// [ArgumentError](在调用 [MissionStore.changeStatus] 时):
///
/// ```
/// planning → executing → completed | failed | cancelled
///                │  ↑
///                ▼  │
///           waitingApproval
/// ```
///
/// 即:planning 只能进入 executing;executing 可以收束到 completed /
/// failed / cancelled,或挂起到 waitingApproval;waitingApproval 只能
/// 回到 executing;终态(completed / failed / cancelled)不可再迁移。
class MissionStore {
  MissionStore(this._prefs);

  final SharedPreferences _prefs;

  /// 持久化键(v3 新增,独立于既有 shelly.* 键,互不影响)。
  static const storageKey = 'shelly.mission.missions';

  /// 硬容量上限:超出时最旧的使命被丢弃(最新优先语义)。
  static const int maxMissions = 100;

  /// 进程级 id 自增计数,保证同一毫秒内创建的使命 id 也不重复
  /// (与 MemoryStore 的做法一致)。
  static int _nextId = 0;

  /// 读取全部使命,按存储顺序返回(最新创建的在前)。
  ///
  /// 键缺失返回空列表;载荷不是合法 JSON、或顶层不是数组时回退为空
  /// (损坏静默清空,不崩溃)。单条记录形状非法时逐条跳过,不影响其余。
  List<AgentMission> listMissions() {
    final raw = _prefs.getString(storageKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) AgentMission.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// 按 id 查找使命;不存在时返回 null。
  AgentMission? getById(String id) {
    for (final mission in listMissions()) {
      if (mission.id == id) return mission;
    }
    return null;
  }

  /// 创建一个新使命:生成唯一 id,初始状态为
  /// [MissionStatus.planning],插入到列表最前(最新优先)并落盘。
  /// 返回创建出的使命。
  ///
  /// 显式传入 [at] 仅供测试;生产环境使用当前时间。
  Future<AgentMission> createMission({
    required String goalId,
    required String title,
    List<String> plan = const [],
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    final mission = AgentMission(
      id: 'mission-${_nextId++}-${now.millisecondsSinceEpoch}',
      goalId: goalId,
      title: title,
      plan: List<String>.of(plan),
      status: MissionStatus.planning,
      taskIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    await _save([mission, ...listMissions()]);
    return mission;
  }

  /// 用 [mission] 的内容整体替换同 id 的既有记录(位置保持不变)。
  /// 时间戳由调用方通过 copyWith 自行维护,本方法不做二次加工。
  /// 返回落盘后的使命;id 不存在时返回 null,不做任何写入。
  Future<AgentMission?> update(AgentMission mission) async {
    final missions = listMissions();
    final index = missions.indexWhere((m) => m.id == mission.id);
    if (index < 0) return null;
    final next = [...missions]..[index] = mission;
    await _save(next);
    return mission;
  }

  /// 把一个任务 id 挂到使命上:追加到 [AgentMission.taskIds] 末尾,
  /// 重复挂载会被忽略(幂等)。返回更新后的使命;使命不存在时返回 null。
  ///
  /// 显式传入 [at] 仅供测试;生产环境使用当前时间戳刷新 updatedAt。
  Future<AgentMission?> attachTask(
    String missionId,
    String taskId, {
    DateTime? at,
  }) async {
    final missions = listMissions();
    final index = missions.indexWhere((m) => m.id == missionId);
    if (index < 0) return null;
    final current = missions[index];
    if (current.taskIds.contains(taskId)) return current;
    final updated = current.copyWith(
      taskIds: [...current.taskIds, taskId],
      updatedAt: at ?? DateTime.now(),
    );
    final next = [...missions]..[index] = updated;
    await _save(next);
    return updated;
  }

  /// 把使命 [missionId] 迁移到状态 [to]。
  ///
  /// 仅允许类文档中列出的合法迁移边;非法迁移抛 [ArgumentError],
  /// 且不产生任何写入(守卫先于落盘)。终态不可迁出。成功时返回
  /// 更新后的使命(updatedAt 刷新为 [at] 或当前时间)。
  Future<AgentMission> changeStatus(
    String missionId,
    MissionStatus to, {
    DateTime? at,
  }) async {
    final missions = listMissions();
    final index = missions.indexWhere((m) => m.id == missionId);
    if (index < 0) {
      throw ArgumentError('使命不存在: $missionId');
    }
    final from = missions[index].status;
    if (!isLegalTransition(from, to)) {
      throw ArgumentError('非法的使命状态迁移: ${from.name} → ${to.name}');
    }
    final updated = missions[index].copyWith(
      status: to,
      updatedAt: at ?? DateTime.now(),
    );
    final next = [...missions]..[index] = updated;
    await _save(next);
    return updated;
  }

  /// 状态机守卫:判断 from → to 是否为合法迁移边。供 [changeStatus]
  /// 与测试使用,规则见类文档。
  static bool isLegalTransition(MissionStatus from, MissionStatus to) {
    switch (from) {
      case MissionStatus.planning:
        return to == MissionStatus.executing;
      case MissionStatus.executing:
        return to == MissionStatus.completed ||
            to == MissionStatus.failed ||
            to == MissionStatus.cancelled ||
            to == MissionStatus.waitingApproval;
      case MissionStatus.waitingApproval:
        return to == MissionStatus.executing;
      // 终态不可迁出。
      case MissionStatus.completed:
      case MissionStatus.failed:
      case MissionStatus.cancelled:
        return false;
    }
  }

  /// 清空整个使命仓库(删除持久化键)。用于测试与“重置”类功能。
  Future<void> deleteAll() => _prefs.remove(storageKey);

  /// 落盘:容量封顶后整体重写 JSON 数组(最新在前)。
  Future<void> _save(List<AgentMission> missions) => _prefs.setString(
        storageKey,
        jsonEncode([
          for (final mission in missions.take(maxMissions)) mission.toJson(),
        ]),
      );
}
