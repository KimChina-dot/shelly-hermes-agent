import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_store.dart';

/// One curated MCP server preset in the 插件仓库 (PHASE 42). [command],
/// [args] and [env] describe how the well-known server launches through a
/// local stdio transport; installing a preset registers exactly this
/// launch line in the MCP connector config (see [PluginRepoStore]).
class PluginPreset {
  const PluginPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.command,
    this.args = const [],
    this.env = const {},
  });

  final String id;
  final String name;

  /// One sentence on what installing the preset enables.
  final String description;

  /// Executable that hosts the MCP server (stdio transport).
  final String command;
  final List<String> args;
  final Map<String, String> env;

  /// `command args…` hint shown on the catalog card.
  String get launchLine => [command, ...args].join(' ');
}

/// The well-known MCP server presets shipped with the app. Ids are stable:
/// they persist in [PluginRepoStore.installedIdsKey] and must never be
/// renamed once released.
const List<PluginPreset> pluginPresets = [
  PluginPreset(
    id: 'filesystem',
    name: 'Filesystem',
    description: '在授权目录内读写与搜索文件,任务可直接操作本地文件。',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-filesystem', '.'],
  ),
  PluginPreset(
    id: 'fetch',
    name: 'Fetch',
    description: '抓取网页并转成 Markdown,联网查资料更省 token。',
    command: 'uvx',
    args: ['mcp-server-fetch'],
  ),
  PluginPreset(
    id: 'memory',
    name: 'Memory',
    description: '知识图谱式长期记忆,跨会话记住人物、项目与事实。',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-memory'],
    env: {'MEMORY_FILE_PATH': 'memory.json'},
  ),
  PluginPreset(
    id: 'git',
    name: 'Git',
    description: '对本地仓库执行 diff、log、commit 等版本管理操作。',
    command: 'uvx',
    args: ['mcp-server-git'],
  ),
  PluginPreset(
    id: 'sqlite',
    name: 'SQLite',
    description: '查询与修改 SQLite 数据库,适合结构化数据分析。',
    command: 'uvx',
    args: ['mcp-server-sqlite', '--db-path', 'shelly.db'],
  ),
  PluginPreset(
    id: 'everything',
    name: 'Everything',
    description: '官方测试服务器,覆盖全部 MCP 能力,用于验证连接器。',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-everything'],
  ),
];

/// Installed-preset registry for the 插件仓库 (PHASE 42). Installed ids
/// live in one JSON list under [installedIdsKey]; installing a preset also
/// writes through to the MCP connector config in [SettingsStore], so the
/// server entry (command/args/env) shows up alongside the HTTP connectors.
/// Both writes are idempotent — neither side ever duplicates.
class PluginRepoStore {
  PluginRepoStore(this._prefs, this._settings);

  final SharedPreferences _prefs;
  final SettingsStore _settings;

  /// JSON list of installed preset ids.
  static const installedIdsKey = 'shelly.plugin.installed';

  /// Server id a preset registers as in the MCP connector config.
  static String mcpEntryId(String presetId) => 'preset.$presetId';

  PluginPreset? presetById(String id) {
    for (final preset in pluginPresets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  List<String> loadInstalledIds() {
    final raw = _prefs.getString(installedIdsKey);
    if (raw == null) return const [];
    try {
      return [
        for (final id in jsonDecode(raw) as List<dynamic>)
          if (id is String) id,
      ];
    } on FormatException {
      return const [];
    }
  }

  bool isInstalled(String presetId) =>
      loadInstalledIds().contains(presetId);

  /// Registers [preset]: adds its server entry to the MCP connector config
  /// (skipped when already present) and records the id. Re-installing an
  /// installed preset is a no-op and returns false.
  Future<bool> install(PluginPreset preset) async {
    final ids = [...loadInstalledIds()];
    if (ids.contains(preset.id)) return false;
    final entryId = mcpEntryId(preset.id);
    final servers = _settings.loadMcpStdioServers();
    if (!servers.any((server) => server.id == entryId)) {
      await _settings.saveMcpStdioServers([
        ...servers,
        McpStdioServerConfig(
          id: entryId,
          name: preset.name,
          command: preset.command,
          args: preset.args,
          env: preset.env,
        ),
      ]);
    }
    ids.add(preset.id);
    await _prefs.setString(installedIdsKey, jsonEncode(ids));
    return true;
  }

  /// Removes the preset id and its MCP connector entry; returns false
  /// (and touches nothing) when the preset was never installed.
  Future<bool> uninstall(String presetId) async {
    final ids = [...loadInstalledIds()];
    if (!ids.contains(presetId)) return false;
    final entryId = mcpEntryId(presetId);
    await _settings.saveMcpStdioServers([
      for (final server in _settings.loadMcpStdioServers())
        if (server.id != entryId) server,
    ]);
    ids.remove(presetId);
    await _prefs.setString(installedIdsKey, jsonEncode(ids));
    return true;
  }
}

final pluginRepoProvider = FutureProvider<PluginRepoStore>((ref) async {
  final settings = await ref.watch(settingsStoreProvider.future);
  return PluginRepoStore(await SharedPreferences.getInstance(), settings);
});
