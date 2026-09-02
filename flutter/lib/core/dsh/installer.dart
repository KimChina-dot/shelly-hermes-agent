import 'dart:convert';

import '../shell/shell_executor.dart';
import '../tools/workspace.dart';
import 'manifest.dart';
import 'plugin.dart';
import 'registry.dart';

/// Local installation (PHASE 15): a plugin ships as a `manifest.json` file
/// (optionally inside a plugin folder) in the workspace. The installer
/// validates, stages it under `.shelly/plugins/<id>/manifest.json`, and
/// registers the matching runtime plugin. Shell-runtime plugins are fully
/// declarative; dart-runtime plugins must be embedded in the app build
/// (matched by [embedded]) — dynamic code loading does not exist here.
class DshInstaller {
  DshInstaller({
    required this.registry,
    required this.workspace,
    this.embedded = const {},
  });

  final DshPluginRegistry registry;
  final Workspace workspace;

  /// Embedded dart-runtime plugins keyed by manifest id.
  final Map<String, DshPlugin> embedded;

  static const _stagingRoot = '.shelly/plugins';

  /// Installs from a manifest file path inside the workspace.
  Future<DshPlugin> installFrom(String manifestPath,
      {ShellExecutor? shell}) async {
    final text = await workspace.readFile(manifestPath);
    if (text == null) {
      throw DshManifestException('manifest not found: $manifestPath');
    }
    return installFromText(text, shell: shell);
  }

  /// Installs from raw manifest JSON text.
  Future<DshPlugin> installFromText(String text, {ShellExecutor? shell}) async {
    final manifest = DshManifest.parse(text);
    final plugin = _create(manifest, shell: shell);
    await _stage(manifest);
    registry.register(plugin);
    await registry.load(
      manifest.id,
      workspace: workspace,
      shell: shell,
    );
    await registry.enable(manifest.id);
    return plugin;
  }

  Future<void> uninstall(String pluginId) async {
    // Bring it down through the lifecycle before deleting files.
    final lifecycle = registry.lifecycleOf(pluginId);
    if (lifecycle == DshLifecycle.enabled) await registry.disable(pluginId);
    if (lifecycle == DshLifecycle.enabled ||
        lifecycle == DshLifecycle.loaded ||
        lifecycle == DshLifecycle.disabled) {
      await registry.unload(pluginId);
    }
    registry.unregister(pluginId);
    await workspace.deleteFile('$_stagingRoot/$pluginId/manifest.json');
  }

  DshPlugin _create(DshManifest manifest, {ShellExecutor? shell}) {
    switch (manifest.runtime) {
      case 'shell':
        return ShellPlugin(manifest);
      case 'dart':
        final plugin = embedded[manifest.id];
        if (plugin == null) {
          throw DshManifestException(
              'dart-runtime plugin ${manifest.id} is not embedded in this build');
        }
        return plugin;
      default:
        throw DshManifestException('unsupported runtime: ${manifest.runtime}');
    }
  }

  Future<void> _stage(DshManifest manifest) async {
    await workspace.writeFile(
      '$_stagingRoot/${manifest.id}/manifest.json',
      jsonEncode(manifest.toJson()),
    );
  }
}
