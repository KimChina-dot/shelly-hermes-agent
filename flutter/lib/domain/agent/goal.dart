/// v3 Agent 域模型:目标(Goal)。
///
/// 目标是 Agent 工作的最高层意图载体:用户给出一个想要达成的结果,
/// Agent 围绕它拆解出使命(Mission)→ 任务(Task)的执行链。
/// 本文件是纯数据层,不依赖任何存储或运行时组件。
library;

/// 目标的生命周期状态。
enum GoalStatus {
  /// 进行中:目标仍是当前工作焦点。
  active,

  /// 已完成:目标已达成。
  completed,

  /// 已归档:目标被放弃或收起,不再参与活跃工作流。
  archived,
}

/// 目标:描述“要达成什么”的最高层抽象。
class AgentGoal {
  const AgentGoal({
    required this.id,
    required this.title,
    this.description = '',
    this.status = GoalStatus.active,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
  });

  /// 全局唯一标识。
  final String id;

  /// 目标短标题。
  final String title;

  /// 详细描述(动机、验收标准等),可为空串。
  final String description;

  /// 当前生命周期状态,默认 [GoalStatus.active]。
  final GoalStatus status;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近一次修改时间。
  final DateTime updatedAt;

  /// 关联的项目 id;无项目上下文时为 null。
  final String? projectId;

  /// 序列化为 JSON 兼容的 Map;可选字段仅在非空时写出。
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (projectId != null) 'projectId': projectId,
      };

  /// 从 JSON 宽松解码:未知状态名回退 [GoalStatus.active],缺失/非法
  /// 字段一律兜底,保证任何 Map 输入都不会抛出 FormatException 之外的
  /// 异常(遵循全库“解码不抛”守则,见 docs/audit/DATA_MODEL_MAP.md)。
  static AgentGoal fromJson(Map<String, dynamic> json) => AgentGoal(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        status: _statusFromName(json['status']),
        createdAt: _parseDate(json['createdAt']),
        updatedAt: _parseDate(json['updatedAt']),
        projectId: json['projectId'] as String?,
      );

  /// 宽松状态解码:未知或缺失的状态名落回 [GoalStatus.active]。
  static GoalStatus _statusFromName(Object? value) {
    if (value is String) {
      for (final status in GoalStatus.values) {
        if (status.name == value) return status;
      }
    }
    return GoalStatus.active;
  }

  /// 宽松时间解码:非法字符串落回当前时间(与 MemoryFact 一致)。
  static DateTime _parseDate(Object? value) =>
      value is String && DateTime.tryParse(value) != null
          ? DateTime.parse(value)
          : DateTime.now();

  /// 返回按给定字段覆盖后的副本;传 null 表示保留原值。
  AgentGoal copyWith({
    String? id,
    String? title,
    String? description,
    GoalStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? projectId,
  }) =>
      AgentGoal(
        id: id ?? this.id,
        title: title ?? this.title,
        description: description ?? this.description,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        projectId: projectId ?? this.projectId,
      );

  @override
  bool operator ==(Object other) =>
      other is AgentGoal &&
      other.id == id &&
      other.title == title &&
      other.description == description &&
      other.status == status &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.projectId == projectId;

  @override
  int get hashCode =>
      Object.hash(id, title, description, status, createdAt, updatedAt, projectId);
}
