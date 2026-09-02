import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/agent_profile.dart';
import '../core/models.dart';
import '../platform/secure_box.dart';

/// Model endpoint configuration. The API key is stored locally (secure
/// AndroidKeyStore storage replaces this on the Android host in stage 5)
/// and is never logged or echoed to the UI in full.
class ModelConfig {
  const ModelConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isComplete => baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  ModelConfig copyWith({String? baseUrl, String? apiKey, String? model}) =>
      ModelConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() =>
      {'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};

  static ModelConfig fromJson(Map<String, dynamic> json) => ModelConfig(
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? '',
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
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final int messageCount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'messageCount': messageCount,
      };

  static ConversationSummary fromJson(Map<String, dynamic> json) =>
      ConversationSummary(
        id: json['id'] as String,
        title: json['title'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        messageCount: json['messageCount'] as int,
      );
}

/// Key-value settings and checkpoint persistence backed by
/// SharedPreferences (works on Android and the web dev harness).
class SettingsStore {
  /// When [secureBox] is provided the API key is persisted through it
  /// (AndroidKeyStore on Android) and never written into the plain prefs
  /// JSON; an in-memory cache keeps sync reads working after restore.
  SettingsStore(this._prefs, {SecureBox? secureBox}) : _secure = secureBox;

  final SharedPreferences _prefs;
  final SecureBox? _secure;
  String _apiKeyCache = '';

  static const _modelConfigKey = 'shelly.model.config';
  static const _apiKeySecureKey = 'model.apiKey';
  static const _conversationsKey = 'shelly.conversations';
  static const _checkpointPrefix = 'shelly.checkpoint.';
  static const _profilesKey = 'shelly.agent.profiles';
  static const _activeProfileKey = 'shelly.agent.profile.active';

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
