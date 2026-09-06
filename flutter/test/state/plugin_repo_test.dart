import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/mcp/mcp_client.dart';
import 'package:shelly_hermes/state/plugin_repo.dart';
import 'package:shelly_hermes/state/settings_store.dart';

void main() {
  late SharedPreferences prefs;
  late SettingsStore settings;
  late PluginRepoStore repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    settings = SettingsStore(prefs);
    repo = PluginRepoStore(prefs, settings);
  });

  group('preset catalog', () {
    test('covers the well-known MCP servers with unique ids', () {
      expect(pluginPresets, isNotEmpty);
      expect(
        pluginPresets.map((p) => p.id),
        containsAll(
            ['filesystem', 'fetch', 'memory', 'git', 'sqlite', 'everything']),
      );
      final ids = pluginPresets.map((p) => p.id).toList();
      expect(ids, ids.toSet().toList(), reason: 'preset ids must be unique');
    });

    test('every preset is fully described and launchable', () {
      for (final preset in pluginPresets) {
        expect(preset.id, isNotEmpty);
        expect(preset.name, isNotEmpty, reason: '${preset.id} needs a name');
        expect(preset.description, isNotEmpty,
            reason: '${preset.id} needs a description');
        expect(preset.command, isNotEmpty,
            reason: '${preset.id} needs a command');
        expect(preset.args, everyElement(isA<String>()));
        expect(preset.env.keys, everyElement(isA<String>()));
        expect(preset.env.values, everyElement(isA<String>()));
        expect(preset.launchLine, startsWith(preset.command));
      }
    });

    test('presetById resolves catalog entries and rejects unknown ids', () {
      expect(repo.presetById('filesystem')?.name, 'Filesystem');
      expect(repo.presetById('no-such-preset'), isNull);
    });
  });

  group('PluginRepoStore', () {
    test('install writes the MCP config entry and records the id', () async {
      final preset = repo.presetById('filesystem')!;

      expect(await repo.install(preset), isTrue);
      expect(repo.isInstalled('filesystem'), isTrue);

      final servers = settings.loadMcpStdioServers();
      expect(servers, hasLength(1));
      expect(servers.single.id, PluginRepoStore.mcpEntryId('filesystem'));
      expect(servers.single.name, preset.name);
      expect(servers.single.command, preset.command);
      expect(servers.single.args, preset.args);
      expect(servers.single.env, preset.env);

      expect(
        jsonDecode(prefs.getString(PluginRepoStore.installedIdsKey)!),
        ['filesystem'],
      );
    });

    test('installed ids round-trip into a fresh store', () async {
      await repo.install(repo.presetById('memory')!);

      final revived = PluginRepoStore(prefs, settings);
      expect(revived.isInstalled('memory'), isTrue);
      expect(revived.loadInstalledIds(), ['memory']);
      // The MCP connector entry the first install wrote is still there.
      expect(
        settings.loadMcpStdioServers().single.id,
        PluginRepoStore.mcpEntryId('memory'),
      );
    });

    test('reinstall is idempotent and never duplicates', () async {
      final preset = repo.presetById('fetch')!;

      expect(await repo.install(preset), isTrue);
      expect(await repo.install(preset), isFalse,
          reason: 'reinstall must be a no-op');
      expect(repo.loadInstalledIds(), ['fetch']);
      expect(settings.loadMcpStdioServers(), hasLength(1));

      // A second preset installs alongside; the first stays unduplicated.
      expect(await repo.install(repo.presetById('git')!), isTrue);
      expect(await repo.install(preset), isFalse);
      expect(repo.loadInstalledIds(), ['fetch', 'git']);
      final ids = settings
          .loadMcpStdioServers()
          .map((server) => server.id)
          .toList();
      expect(ids, ['preset.fetch', 'preset.git']);
    });

    test('install never duplicates a connector entry that already exists',
        () async {
      final preset = repo.presetById('fetch')!;
      await settings.saveMcpStdioServers([
        McpStdioServerConfig(
          id: PluginRepoStore.mcpEntryId(preset.id),
          name: preset.name,
          command: preset.command,
          args: preset.args,
          env: preset.env,
        ),
      ]);

      expect(await repo.install(preset), isTrue);
      expect(settings.loadMcpStdioServers(), hasLength(1));
      expect(repo.loadInstalledIds(), ['fetch']);
    });

    test('uninstall removes both the id and the MCP entry', () async {
      await repo.install(repo.presetById('filesystem')!);
      await repo.install(repo.presetById('sqlite')!);
      // HTTP connectors live in a separate list and must stay untouched.
      await settings.saveMcpServers([
        const McpServerConfig(
            id: 's1', name: 'github', url: 'https://mcp.example.com/mcp'),
      ]);

      expect(await repo.uninstall('filesystem'), isTrue);
      expect(repo.isInstalled('filesystem'), isFalse);
      expect(repo.loadInstalledIds(), ['sqlite']);
      expect(
        settings.loadMcpStdioServers().map((s) => s.id),
        ['preset.sqlite'],
      );

      // Uninstalling again (or an unknown preset) is a no-op.
      expect(await repo.uninstall('filesystem'), isFalse);
      expect(await repo.uninstall('never-heard-of'), isFalse);
      expect(repo.loadInstalledIds(), ['sqlite']);
      expect(settings.loadMcpServers(), hasLength(1),
          reason: 'HTTP connector config must survive preset installs');
    });

    test('corrupt installed-id records fall back to an empty list', () async {
      await prefs.setString(PluginRepoStore.installedIdsKey, '{not json');

      expect(repo.loadInstalledIds(), isEmpty);
      expect(repo.isInstalled('filesystem'), isFalse);
    });
  });
}
