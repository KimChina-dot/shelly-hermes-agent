/// v3 Agent 域模型:使命(Mission)。
///
/// 使命是目标(Goal)之下的执行层抽象:为实现一个目标而制定的
/// 计划(步骤文本列表)及其派生出的任务(Task)集合。
/// 本文件是纯数据层,不依赖任何存储或运行时组件。
library;

/// 使命的生命周期状态(状态机见 [AgentMission] 与 MissionStore 的守卫)。
enum MissionStatus {
  /// 规划中:计划正在制定,尚未开始执行。
  planning,

  /// 执行中:计划已批准,任务正在推进。
  executing,

  /// 等待审批:执行被挂起,等待用户/审批方放行。
  waitingApproval,

  /// 已完成:全部任务成功收束。
  completed,

  /// 已失败:执行遇到不可恢复的失败。
  failed,

  /// 已取消:被用户或系统主动取消。
  cancelled,
}

/// 使命:目标之下的一套计划与任务编排。
class AgentMission {
  const AgentMission({
    required this.id,
    required this.goalId,
    required this.title,
    this.plan = const [],
    this.status = MissionStatus.planning,
    this.taskIds = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  /// 全局唯一标识。
  final String id;

  /// 所属目标的 id(逻辑外键,指向 AgentGoal)。
  final String goalId;

  /// 使命短标题。
  final String title;

  /// 计划:有序的步骤文本列表(自然语言描述,执行层再细化为任务)。
  final List<String> plan;

  /// 当前生命周期状态,默认 [MissionStatus.planning]。
  final MissionStatus status;

  /// 派生任务 id 列表(逻辑外键,指向 AgentTaskRecord)。
  final List<String> taskIds;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近一次修改时间。
  final DateTime updatedAt;

  /// 序列化为 JSON 兼容的 Map;列表字段始终写出,可选缺失时宽松兜底。
  Map<String, dynamic> toJson() => {
        'id': id,
        'goalId': goalId,
        'title': title,
        'plan': plan,
        'status': status.name,
        'taskIds': taskIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// 从 JSON 宽松解码:未知状态名回退 [MissionStatus.planning],
  /// 列表字段逐项类型过滤,保证任何 Map 输入都不会抛出
  /// FormatException 之外的异常(遵循全库“解码不抛”守则)。
  static AgentMission fromJson(Map<String, dynamic> json) => AgentMission(
        id: json['id'] as String? ?? '',
        goalId: json['goalId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        plan: [
          for (final entry in json['plan'] as List<dynamic>? ?? const [])
            if (entry is String) entry,
        ],
        status: _statusFromName(json['status']),
        taskIds: [
          for (final entry in json['taskIds'] as List<dynamic>? ?? const [])
            if (entry is String) entry,
        ],
        createdAt: _parseDate(json['createdAt']),
        updatedAt: _parseDate(json['updatedAt']),
      );

  /// 宽松状态解码:未知或缺失的状态名落回 [MissionStatus.planning]。
  static MissionStatus _statusFromName(Object? value) {
    if (value is String) {
      for (final status in MissionStatus.values) {
        if (status.name == value) return status;
      }
    }
    return MissionStatus.planning;
  }

  /// 返回按给定字段覆盖后的副本;列表字段默认浅拷贝防共享突变。
  AgentMission copyWith({
    String? id,
    String? goalId,
    String? title,
    List<String>? plan,
    MissionStatus? status,
    List<String>? taskIds,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      AgentMission(
        id: id ?? this.id,
        goalId: goalId ?? this.goalId,
        title: title ?? this.title,
        plan: plan ?? List<String>.of(this.plan),
        status: status ?? this.status,
        taskIds: taskIds ?? List<String>.of(this.taskIds),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is AgentMission &&
      other.id == id &&
      other.goalId == goalId &&
      other.title == title &&
      _listEquals(other.plan, plan) &&
      other.status == status &&
      _listEquals(other.taskIds, taskIds) &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        goalId,
        title,
        Object.hashAll(plan),
        status,
        Object.hashAll(taskIds),
        createdAt,
        updatedAt,
      );
}

/// 宽松时间解码:非法字符串落回当前时间(与 MemoryFact / AgentGoal 一致)。
DateTime _parseDate(Object? value) =>
    value is String && DateTime.tryParse(value) != null
        ? DateTime.parse(value)
        : DateTime.now();

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
