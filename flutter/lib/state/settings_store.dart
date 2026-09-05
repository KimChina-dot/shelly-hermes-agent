import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/agent_profile.dart';
import '../core/gateway/context_window.dart';
import '../core/hermes/memory_settings.dart';
import '../core/models.dart';
import '../core/mcp/mcp_client.dart';
import '../core/task_recovery.dart';
import '../platform/secure_box.dart';

/// Model endpoint configuration. The API key is stored locally (secure
/// AndroidKeyStore storage replaces this on the Android host in stage 5)
/// and is never logged or echoed to the UI in full.
class ModelConfig {
  const ModelConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.contextWindow = 0,
    this.webSearchEnabled = false,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  /// Manual context-window override in tokens; 0 resolves via
  /// [contextWindowForModel] presets from the model id.
  final int contextWindow;

  /// Turns on the provider's server-side web-search plugin when the
  /// endpoint supports one (see [webSearchSupportFor]).
  final bool webSearchEnabled;

  bool get isComplete => baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  /// The window the context compactor plans against.
  int get effectiveContextWindow =>
      contextWindow > 0 ? contextWindow : contextWindowForModel(model);

  ModelConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    int? contextWindow,
    bool? webSearchEnabled,
  }) =>
      ModelConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        contextWindow: contextWindow ?? this.contextWindow,
        webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
      );

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        if (contextWindow > 0) 'contextWindow': contextWindow,
        if (webSearchEnabled) 'webSearchEnabled': true,
      };

  static ModelConfig fromJson(Map<String, dynamic> json) => ModelConfig(
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? '',
        contextWindow: (json['contextWindow'] as num?)?.toInt() ?? 0,
        webSearchEnabled: json['webSearchEnabled'] as bool? ?? false,
      );

  /// Masks the key for display: keeps a short prefix and suffix.
  String get maskedApiKey {
    if (apiKey.isEmpty) return '';
    if (apiKey.length <= 8) return '••••';
    return '${apiKey.substring(0, 4)}••••${apiKey.substring(apiKey.length - 4)}';
  }
}

/// Conversation summary for the history page.
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messageCount,
    this.pinned = false,
    this.modelId,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final int messageCount;
  final bool pinned;

  /// Model the conversation last ran with (informational; the global
  /// model config still decides what the next task uses).
  final String? modelId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'messageCount': messageCount,
        'pinned': pinned,
        if (modelId != null) 'modelId': modelId,
      };

  static ConversationSummary fromJson(Map<String, dynamic> json) =>
      ConversationSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        messageCount: json['messageCount'] as int,
        pinned: json['pinned'] as bool? ?? false,
        modelId: json['modelId'] as String?,
      );
}

/// History ordering: pinned first, then most recently updated.
List<ConversationSummary> sortConversations(List<ConversationSummary> list) {
  final sorted = [...list]..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  return sorted;
}

/// Key-value settings and checkpoint persistence backed by
/// SharedPreferences (works on Android and the web dev harness).
class SettingsStore implements TaskRecoveryStore {
  /// When [secureBox] is provided the API key is persisted through it
  /// (AndroidKeyStore on Android) and never written into the plain prefs
  /// JSON; an in-memory cache keeps sync reads working after restore.
  SettingsStore(this._prefs, {SecureBox? secureBox}) : _secure = secureBox;

  final SharedPreferences _prefs;
  final SecureBox? _secure;
  String _apiKeyCache = '';

  static const _modelConfigKey = 'shelly.model.config';
  static const _auxModelConfigKey = 'shelly.model.aux';
  static const _auxEnabledKey = 'shelly.model.aux.enabled';
  static const _apiKeySecureKey = 'model.apiKey';
  static const _conversationsKey = 'shelly.conversations';
  static const _checkpointPrefix = 'shelly.checkpoint.';
  static const _profilesKey = 'shelly.agent.profiles';
  static const _activeProfileKey = 'shelly.agent.profile.active';
  static const _activeTaskKey = 'shelly.task.active';
  static const _memorySettingsKey = 'shelly.memory.settings';
  static const _mcpServersKey = 'shelly.mcp.servers';

  /// Convenience accessor for reactive UI reads.
  ModelConfig get modelConfig => loadModelConfig();

  ModelConfig loadModelConfig() {
    final raw = _prefs.getString(_modelConfigKey);
    if (raw == null) return const ModelConfig();
    try {
      final config = ModelConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (_secure == null) return config;
      return config.copyWith(apiKey: _apiKeyCache);
    } on FormatException {
      return const ModelConfig();
    }
  }

  Future<void> saveModelConfig(ModelConfig config) async {
    if (_secure == null) {
      await _prefs.setString(_modelConfigKey, jsonEncode(config.toJson()));
      return;
    }
    _apiKeyCache = config.apiKey;
    await _secure.write(_apiKeySecureKey, config.apiKey);
    await _prefs.setString(
      _modelConfigKey,
      jsonEncode(config.copyWith(apiKey: '').toJson()),
    );
  }

  /// Loads the API key out of secure storage into the sync read cache.
  /// Call once after construction, before the UI reads the config.
  Future<void> restoreApiKey() async {
    final box = _secure;
    if (box == null) return;
    var key = await box.read(_apiKeySecureKey);
    if ((key == null || key.isEmpty)) {
      // Legacy configs kept the key inside the prefs JSON; migrate it.
      final raw = _prefs.getString(_modelConfigKey);
      if (raw != null) {
        try {
          key = ModelConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>).apiKey;
        } on FormatException {
          // Corrupt legacy record — treat as no key.
        }
      }
    }
    _apiKeyCache = key ?? '';
  }

  /// The auxiliary ("cheap") model that serves lightweight jobs — context
  /// compaction summaries, oversized tool-output digests, session titles.
  /// Reuses the [ModelConfig] structure; its API key is optional and those
  /// jobs fall back to the main model's key when empty (same vendor in
  /// practice), so the picker sheet stores none.
  ModelConfig loadAuxModelConfig() {
    final raw = _prefs.getString(_auxModelConfigKey);
    if (raw == null) return const ModelConfig();
    try {
      return ModelConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return const ModelConfig();
    }
  }

  Future<void> saveAuxModelConfig(ModelConfig config) =>
      _prefs.setString(_auxModelConfigKey, jsonEncode(config.toJson()));

  /// Lightweight jobs only switch to the auxiliary model when this switch
  /// is on and [loadAuxModelConfig] names a usable endpoint.
  bool get auxEnabled => _prefs.getBool(_auxEnabledKey) ?? false;

  Future<void> setAuxEnabled(bool enabled) =>
      _prefs.setBool(_auxEnabledKey, enabled);

  List<ConversationSummary> loadConversations() {
    final raw = _prefs.getString(_conversationsKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => ConversationSummary.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return const [];
    }
  }

  Future<void> saveConversations(List<ConversationSummary> conversations) =>
      _prefs.setString(
        _conversationsKey,
        jsonEncode([for (final c in conversations) c.toJson()]),
      );

  /// Removes a conversation's summary and its persisted checkpoint.
  Future<void> deleteConversation(String id) async {
    final summaries =
        loadConversations().where((c) => c.id != id).toList();
    await saveConversations(summaries);
    await _prefs.remove('$_checkpointPrefix$id');
  }

  Future<void> renameConversation(String id, String title) => _mutateSummary(
        id,
        (c) => ConversationSummary(
          id: c.id,
          title: title,
          updatedAt: c.updatedAt,
          messageCount: c.messageCount,
          pinned: c.pinned,
          modelId: c.modelId,
        ),
      );

  Future<void> setPinned(String id, bool pinned) => _mutateSummary(
        id,
        (c) => ConversationSummary(
          id: c.id,
          title: c.title,
          updatedAt: c.updatedAt,
          messageCount: c.messageCount,
          pinned: c.pinned,
          modelId: c.modelId,
        ),
      );

  Future<void> _mutateSummary(
    String id,
    ConversationSummary Function(ConversationSummary) transform,
  ) async {
    final summaries = loadConversations();
    final index = summaries.indexWhere((c) => c.id == id);
    if (index < 0) return;
    summaries[index] = transform(summaries[index]);
    await saveConversations(summaries);
  }

  @override
  AgentCheckpoint? loadCheckpoint(String conversationId) {
    final raw = _prefs.getString('$_checkpointPrefix$conversationId');
    if (raw == null) return null;
    try {
      return AgentCheckpoint.decode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> saveCheckpoint(String conversationId, AgentCheckpoint checkpoint) =>
      _prefs.setString('$_checkpointPrefix$conversationId', checkpoint.encode());

  /// Agent profiles (PHASE 19). An empty store resolves to the built-in
  /// presets; the active id falls back to the first preset.
  List<AgentProfile> loadProfiles() {
    final raw = _prefs.getString(_profilesKey);
    if (raw == null) return List.of(agentProfilePresets);
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final profiles = decoded
          .map((e) => AgentProfile.fromJson(e as Map<String, dynamic>))
          .where((p) => p.isValid)
          .toList();
      return profiles.isEmpty ? List.of(agentProfilePresets) : profiles;
    } on FormatException {
      return List.of(agentProfilePresets);
    }
  }

  Future<void> saveProfiles(List<AgentProfile> profiles) => _prefs.setString(
        _profilesKey,
        jsonEncode([for (final p in profiles) p.toJson()]),
      );

  /// Hermes memory knobs (V2.1 PHASE 26); corrupt records fall back to
  /// the MemorySettings defaults.
  MemorySettings loadMemorySettings() {
    final raw = _prefs.getString(_memorySettingsKey);
    if (raw == null) return const MemorySettings();
    try {
      return MemorySettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return const MemorySettings();
    }
  }

  Future<void> saveMemorySettings(MemorySettings settings) => _prefs.setString(
        _memorySettingsKey,
        jsonEncode(settings.toJson()),
      );

  List<McpServerConfig> loadMcpServers() {
    final raw = _prefs.getString(_mcpServersKey);
    if (raw == null) return const [];
    try {
      return [
        for (final entry in jsonDecode(raw) as List<dynamic>)
          if (entry is Map<String, dynamic>) McpServerConfig.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> saveMcpServers(List<McpServerConfig> servers) => _prefs.setString(
        _mcpServersKey,
        jsonEncode([for (final server in servers) server.toJson()]),
      );

  String? loadActiveProfileId() => _prefs.getString(_activeProfileKey);

  Future<void> saveActiveProfileId(String? id) => id == null
      ? _prefs.remove(_activeProfileKey)
      : _prefs.setString(_activeProfileKey, id);

  /// The profile tasks actually run with; never null.
  AgentProfile activeProfile() {
    final profiles = loadProfiles();
    final activeId = loadActiveProfileId();
    for (final profile in profiles) {
      if (profile.id == activeId) return profile;
    }
    return profiles.first;
  }

  /// Background-agent recovery port (PHASE 20). The record exists only
  /// while a task runs; it survives process death so the next launch can
  /// detect and resume the interrupted task.
  @override
  TaskRecoveryRecord? loadActiveTask() {
    final raw = _prefs.getString(_activeTaskKey);
    if (raw == null) return null;
    try {
      return TaskRecoveryRecord.decode(raw);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveActiveTask(TaskRecoveryRecord record) =>
      _prefs.setString(_activeTaskKey, record.encode());

  @override
  Future<void> clearActiveTask() => _prefs.remove(_activeTaskKey);
}

final settingsStoreProvider = FutureProvider<SettingsStore>(
  (ref) async {
    final store = SettingsStore(
      await SharedPreferences.getInstance(),
      secureBox: createSecureBox(),
    );
    await store.restoreApiKey();
    return store;
  },
);
