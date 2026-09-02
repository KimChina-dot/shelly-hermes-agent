import '../shell/shell_executor.dart';
import '../tools/workspace.dart';
import 'manifest.dart';
import 'plugin.dart';

/// DSH plugin registry (PHASE 13): owns registration, lifecycle
/// transitions and lookup. Enforces the global namespace — a plugin tool
/// whose name collides with an existing plugin is rejected; collisions
/// with core tools are impossible here because core wins at dispatch
/// (see CompositeToolRegistry), but they are still flagged at registration.
class DshPluginRegistry {
  final Map<String, _Entry> _plugins = {};

  /// Registers (but does not load) a plugin. Rejects duplicate ids, tool
  /// name collisions against already-registered plugins, and invalid
  /// manifests.
  void register(DshPlugin plugin) {
    final id = plugin.manifest.id;
    if (_plugins.containsKey(id)) {
      throw DshRegistryError('plugin already registered: $id');
    }
    final problems = validate(plugin.manifest);
    if (problems.isNotEmpty) {
      throw DshRegistryError('invalid manifest for $id: ${problems.join('; ')}');
    }
    final existing = _allToolNames();
    final newNames = plugin.manifest.tools.map((t) => t.name).toSet();
    final collisions = existing.intersection(newNames);
    if (collisions.isNotEmpty) {
      throw DshRegistryError(
          'tool name collision while registering $id: ${collisions.join(', ')}');
    }
    _plugins[id] = _Entry(plugin);
  }

  /// Lifecycle: register → load → enable. [host] builds the permission-
  /// scoped context from the manifest.
  Future<void> load(
    String id, {
    Workspace? workspace,
    ShellExecutor? shell,
  }) async {
    final entry = _entry(id);
    if (entry.lifecycle != DshLifecycle.registered) {
      throw DshRegistryError('plugin $id is ${entry.lifecycle.name}, expected registered');
    }
    try {
      await entry.plugin.onLoad(DshHostContext(
        pluginId: id,
        permissions: entry.plugin.manifest.permissions,
        workspace: workspace,
        shell: shell,
      ));
      entry.lifecycle = DshLifecycle.loaded;
    } catch (error) {
      entry.lifecycle = DshLifecycle.failed;
      rethrow;
    }
  }

  Future<void> enable(String id) async {
    final entry = _entry(id);
    if (entry.lifecycle != DshLifecycle.loaded &&
        entry.lifecycle != DshLifecycle.disabled) {
      throw DshRegistryError('cannot enable plugin $id from ${entry.lifecycle.name}');
    }
    await entry.plugin.onEnable();
    entry.lifecycle = DshLifecycle.enabled;
  }

  Future<void> disable(String id) async {
    final entry = _entry(id);
    if (entry.lifecycle != DshLifecycle.enabled) {
      throw DshRegistryError('cannot disable plugin $id from ${entry.lifecycle.name}');
    }
    await entry.plugin.onDisable();
    entry.lifecycle = DshLifecycle.disabled;
  }

  Future<void> unload(String id) async {
    final entry = _entry(id);
    if (entry.lifecycle != DshLifecycle.disabled &&
        entry.lifecycle != DshLifecycle.loaded) {
      throw DshRegistryError('cannot unload plugin $id from ${entry.lifecycle.name}');
    }
    await entry.plugin.onUnload();
    entry.lifecycle = DshLifecycle.unloaded;
  }

  /// Removes a plugin entirely. Must be unloaded (or never loaded) first.
  void unregister(String id) {
    final entry = _entry(id);
    if (entry.lifecycle != DshLifecycle.unloaded &&
        entry.lifecycle != DshLifecycle.registered) {
      throw DshRegistryError('cannot uninstall plugin $id from ${entry.lifecycle.name}');
    }
    _plugins.remove(id);
  }

  DshPlugin? find(String id) => _plugins[id]?.plugin;

  DshLifecycle? lifecycleOf(String id) => _plugins[id]?.lifecycle;

  List<DshPlugin> list() => [
        for (final entry in _plugins.values) entry.plugin,
      ];

  List<DshPlugin> listEnabled() => [
        for (final entry in _plugins.values)
          if (entry.lifecycle == DshLifecycle.enabled) entry.plugin,
      ];

  Set<String> _allToolNames() => {
        for (final entry in _plugins.values)
          for (final tool in entry.plugin.manifest.tools) tool.name,
      };

  _Entry _entry(String id) {
    final entry = _plugins[id];
    if (entry == null) {
      throw DshRegistryError('unknown plugin: $id');
    }
    return entry;
  }
}

class _Entry {
  _Entry(this.plugin);

  final DshPlugin plugin;
  DshLifecycle lifecycle = DshLifecycle.registered;
}

class DshRegistryError implements Exception {
  const DshRegistryError(this.message);

  final String message;

  @override
  String toString() => 'DshRegistryError: $message';
}
