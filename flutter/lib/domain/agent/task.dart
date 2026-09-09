/// v3 Agent 域模型:任务(Task)。
///
/// 任务是使命(Mission)之下的最小可执行单元。类名特意取
/// [AgentTaskRecord],避免与仓库中既有的 TaskQueue/任务恢复概念
/// (lib/core/task_queue.dart、lib/core/task_recovery.dart)混淆。
/// 本文件是纯数据层,不依赖任何存储或运行时组件。
library;

/// 任务的生命周期状态。
enum AgentTaskStatus {
  /// 待执行:尚未开始。
  pending,

  /// 执行中。
  running,

  /// 已完成。
  completed,

  /// 已失败。
  failed,

  /// 已跳过:主动放弃执行(如计划变更),不等同于失败。
  skipped,
}

/// 任务记录:使命之下的一次可执行工作项。
class AgentTaskRecord {
  const AgentTaskRecord({
    required this.id,
    required this.missionId,
    required this.title,
    this.status = AgentTaskStatus.pending,
    this.result,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 全局唯一标识。
  final String id;

  /// 所属使命的 id(逻辑外键,指向 AgentMission)。
  final String missionId;

  /// 任务短标题(要做什么)。
  final String title;

  /// 当前生命周期状态,默认 [AgentTaskStatus.pending]。
  final AgentTaskStatus status;

  /// 执行结果摘要;完成或失败后写入,未结束时为 null。
  final String? result;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近一次修改时间。
  final DateTime updatedAt;

  /// 序列化为 JSON 兼容的 Map;可选字段仅在非空时写出。
  Map<String, dynamic> toJson() => {
        'id': id,
        'missionId': missionId,
        'title': title,
        'status': status.name,
        if (result != null) 'result': result,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// 从 JSON 宽松解码:未知状态名回退 [AgentTaskStatus.pending],
  /// 保证任何 Map 输入都不会抛出 FormatException 之外的异常
  /// (遵循全库“解码不抛”守则)。
  static AgentTaskRecord fromJson(Map<String, dynamic> json) => AgentTaskRecord(
        id: json['id'] as String? ?? '',
        missionId: json['missionId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        status: _statusFromName(json['status']),
        result: json['result'] as String?,
        createdAt: _parseDate(json['createdAt']),
        updatedAt: _parseDate(json['updatedAt']),
      );

  /// 宽松状态解码:未知或缺失的状态名落回 [AgentTaskStatus.pending]。
  static AgentTaskStatus _statusFromName(Object? value) {
    if (value is String) {
      for (final status in AgentTaskStatus.values) {
        if (status.name == value) return status;
      }
    }
    return AgentTaskStatus.pending;
  }

  /// 返回按给定字段覆盖后的副本;传 null 表示保留原值。
  AgentTaskRecord copyWith({
    String? id,
    String? missionId,
    String? title,
    AgentTaskStatus? status,
    String? result,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      AgentTaskRecord(
        id: id ?? this.id,
        missionId: missionId ?? this.missionId,
        title: title ?? this.title,
        status: status ?? this.status,
        result: result ?? this.result,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is AgentTaskRecord &&
      other.id == id &&
      other.missionId == missionId &&
      other.title == title &&
      other.status == status &&
      other.result == result &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        missionId,
        title,
        status,
        result,
        createdAt,
        updatedAt,
      );
}

/// 宽松时间解码:非法字符串落回当前时间(与 AgentGoal / AgentMission 一致)。
DateTime _parseDate(Object? value) =>
    value is String && DateTime.tryParse(value) != null
        ? DateTime.parse(value)
        : DateTime.now();
