import 'dart:convert';

/// AgentProfile (V2.0 PHASE 19): a named behavior preset — persona prompt,
/// engine limits, Hermes capture posture and the preferred provider. Pure
/// data; the runtime assembly reads it, the UI edits it.
class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.name,
    this.systemPrompt = '',
    this.autoCapture = true,
    this.maxRounds = 16,
    this.maxToolCalls = 32,
    this.providerId = 'custom',
  });

  final String id;
  final String name;

  /// Prepended as a system message at the start of every fresh task.
  final String systemPrompt;

  /// Whether completed tasks feed the Hermes ledger automatically.
  final bool autoCapture;
  final int maxRounds;
  final int maxToolCalls;

  /// One of the [llmProviderPresets] ids (`providers.dart`); purely a hint
  /// for the profile page — the gateway only sees the resolved base URL.
  final String providerId;

  bool get isValid =>
      id.trim().isNotEmpty &&
      name.trim().isNotEmpty &&
      maxRounds >= 1 &&
      maxRounds <= 200 &&
      maxToolCalls >= 1 &&
      maxToolCalls <= 500;

  /// True for the built-in presets; presets are never edited in place —
  /// the editor copies one into a user-owned profile instead.
  bool get isPreset =>
      agentProfilePresets.where((p) => p.id == id).isNotEmpty;

  /// A user-owned duplicate of this profile (used when editing a preset).
  AgentProfile asEditableCopy({required String newId}) => AgentProfile(
        id: newId,
        name: '$name(自定义)',
        systemPrompt: systemPrompt,
        autoCapture: autoCapture,
        maxRounds: maxRounds,
        maxToolCalls: maxToolCalls,
        providerId: providerId,
      );

  AgentProfile copyWith({
    String? id,
    String? name,
    String? systemPrompt,
    bool? autoCapture,
    int? maxRounds,
    int? maxToolCalls,
    String? providerId,
  }) =>
      AgentProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        autoCapture: autoCapture ?? this.autoCapture,
        maxRounds: maxRounds ?? this.maxRounds,
        maxToolCalls: maxToolCalls ?? this.maxToolCalls,
        providerId: providerId ?? this.providerId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'systemPrompt': systemPrompt,
        'autoCapture': autoCapture,
        'maxRounds': maxRounds,
        'maxToolCalls': maxToolCalls,
        'providerId': providerId,
      };

  static AgentProfile fromJson(Map<String, dynamic> json) => AgentProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        systemPrompt: json['systemPrompt'] as String? ?? '',
        autoCapture: json['autoCapture'] as bool? ?? true,
        maxRounds: (json['maxRounds'] as num?)?.toInt() ?? 16,
        maxToolCalls: (json['maxToolCalls'] as num?)?.toInt() ?? 32,
        providerId: json['providerId'] as String? ?? 'custom',
      );

  String encode() => jsonEncode(toJson());

  static AgentProfile decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

const agentProfilePresets = <AgentProfile>[
  AgentProfile(
    id: 'balanced',
    name: '平衡助手',
    systemPrompt:
        '你是一位务实的工程助手:先读代码再动手,改动尽量小,完成后给出简要总结。',
  ),
  AgentProfile(
    id: 'careful',
    name: '谨慎工程师',
    systemPrompt:
        '你是一位严谨的工程师:任何写操作前先说明计划并等待确认,优先使用低风险只读命令验证假设,拒绝执行不确定的破坏性操作。',
    maxRounds: 24,
    maxToolCalls: 48,
  ),
  AgentProfile(
    id: 'lean',
    name: '轻量执行',
    systemPrompt: '你是一位简洁的执行者:直接完成任务,输出尽量短,不记录经验。',
    maxRounds: 8,
    maxToolCalls: 16,
    autoCapture: false,
  ),
];

AgentProfile? profileById(String id) =>
    agentProfilePresets.where((p) => p.id == id).firstOrNull;
