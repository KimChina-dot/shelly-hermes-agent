/// v3 Agent 域模型:动作(Action)。
///
/// 动作是执行层的一次原子操作记录(通常是调用某个工具/能力),用于
/// 回放执行轨迹与诊断。动作是轻量记录对象(由上层按需持久化),
/// 不直接落盘。本文件是纯数据层,不依赖任何存储或运行时组件。
library;

/// 一次原子动作的执行记录。
class AgentAction {
  const AgentAction({
    required this.id,
    required this.type,
    this.inputSummary = '',
    this.outputSummary = '',
    required this.ok,
    required this.durationMillis,
    required this.at,
  });

  /// 全局唯一标识。
  final String id;

  /// 动作类型(通常是工具 id,如 'web.search'、'fs.read')。
  final String type;

  /// 输入摘要(不含敏感原文,仅供轨迹展示)。
  final String inputSummary;

  /// 输出摘要(不含敏感原文,仅供轨迹展示)。
  final String outputSummary;

  /// 是否成功。
  final bool ok;

  /// 执行耗时(毫秒)。
  final int durationMillis;

  /// 发生时间。
  final DateTime at;

  /// 序列化为 JSON 兼容的 Map;摘要字段始终写出,便于轨迹对齐。
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'inputSummary': inputSummary,
        'outputSummary': outputSummary,
        'ok': ok,
        'durationMillis': durationMillis,
        'at': at.toIso8601String(),
      };

  /// 从 JSON 宽松解码:任何字段缺失/非法都兜底,保证任何 Map 输入
  /// 都不会抛出 FormatException 之外的异常(遵循全库“解码不抛”守则)。
  static AgentAction fromJson(Map<String, dynamic> json) => AgentAction(
        id: json['id'] as String? ?? '',
        type: json['type'] as String? ?? '',
        inputSummary: json['inputSummary'] as String? ?? '',
        outputSummary: json['outputSummary'] as String? ?? '',
        ok: json['ok'] is bool ? json['ok'] as bool : false,
        durationMillis: json['durationMillis'] is int
            ? json['durationMillis'] as int
            : 0,
        at: _parseDate(json['at']),
      );

  /// 宽松时间解码:非法字符串落回当前时间(与各域模型一致)。
  static DateTime _parseDate(Object? value) =>
      value is String && DateTime.tryParse(value) != null
          ? DateTime.parse(value)
          : DateTime.now();

  /// 返回按给定字段覆盖后的副本;传 null 表示保留原值。
  AgentAction copyWith({
    String? id,
    String? type,
    String? inputSummary,
    String? outputSummary,
    bool? ok,
    int? durationMillis,
    DateTime? at,
  }) =>
      AgentAction(
        id: id ?? this.id,
        type: type ?? this.type,
        inputSummary: inputSummary ?? this.inputSummary,
        outputSummary: outputSummary ?? this.outputSummary,
        ok: ok ?? this.ok,
        durationMillis: durationMillis ?? this.durationMillis,
        at: at ?? this.at,
      );

  @override
  bool operator ==(Object other) =>
      other is AgentAction &&
      other.id == id &&
      other.type == type &&
      other.inputSummary == inputSummary &&
      other.outputSummary == outputSummary &&
      other.ok == ok &&
      other.durationMillis == durationMillis &&
      other.at == at;

  @override
  int get hashCode => Object.hash(
        id,
        type,
        inputSummary,
        outputSummary,
        ok,
        durationMillis,
        at,
      );

  @override
  String toString() =>
      'AgentAction($id, $type, ok: $ok, ${durationMillis}ms)';
}
