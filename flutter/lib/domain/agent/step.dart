/// v3 Agent 域模型:步骤(Step)。
///
/// 步骤是任务(Task)内部的执行细分:一个任务可以拆成若干有序步骤
/// 逐个推进。步骤是轻量内存对象(由上层按需持久化),不直接落盘。
/// 本文件是纯数据层,不依赖任何存储或运行时组件。
library;

/// 步骤的生命周期状态。
enum AgentStepStatus {
  /// 待执行:尚未开始。
  pending,

  /// 执行中。
  running,

  /// 已完成。注意与任务/使命层的 completed 不同,步骤层用更短的
  /// done,与执行循环里的口头语一致。
  done,

  /// 已失败。
  failed,
}

/// 步骤:任务内部的一个有序执行片段。
class AgentStep {
  const AgentStep({
    required this.index,
    required this.description,
    this.status = AgentStepStatus.pending,
  });

  /// 在任务内的序号(0 起),决定执行顺序。
  final int index;

  /// 步骤描述(自然语言,说明这一步要做什么)。
  final String description;

  /// 当前生命周期状态,默认 [AgentStepStatus.pending]。
  final AgentStepStatus status;

  /// 序列化为 JSON 兼容的 Map。
  Map<String, dynamic> toJson() => {
        'index': index,
        'description': description,
        'status': status.name,
      };

  /// 从 JSON 宽松解码:未知状态名回退 [AgentStepStatus.pending],
  /// index 缺失/非法时落回 0(遵循全库“解码不抛”守则)。
  static AgentStep fromJson(Map<String, dynamic> json) => AgentStep(
        index: json['index'] is int ? json['index'] as int : 0,
        description: json['description'] as String? ?? '',
        status: _statusFromName(json['status']),
      );

  /// 宽松状态解码:未知或缺失的状态名落回 [AgentStepStatus.pending]。
  static AgentStepStatus _statusFromName(Object? value) {
    if (value is String) {
      for (final status in AgentStepStatus.values) {
        if (status.name == value) return status;
      }
    }
    return AgentStepStatus.pending;
  }

  /// 返回按给定字段覆盖后的副本;传 null 表示保留原值。
  AgentStep copyWith({
    int? index,
    String? description,
    AgentStepStatus? status,
  }) =>
      AgentStep(
        index: index ?? this.index,
        description: description ?? this.description,
        status: status ?? this.status,
      );

  @override
  bool operator ==(Object other) =>
      other is AgentStep &&
      other.index == index &&
      other.description == description &&
      other.status == status;

  @override
  int get hashCode => Object.hash(index, description, status);

  @override
  String toString() => 'AgentStep($index, ${status.name}, $description)';
}
