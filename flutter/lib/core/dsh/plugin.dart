// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../shell/shell_executor.dart';
import '../tools/workspace.dart';
import 'manifest.dart';

/// DSH plugin lifecycle (PHASE 12):
/// registered → loaded → enabled ⇄ disabled → unloaded → uninstalled.
enum DshLifecycle { registered, loaded, enabled, disabled, unloaded, failed }

class DshPermissionDenied implements Exception {
  const DshPermissionDenied(this.permission, this.pluginId);

  final String permission;
  final String pluginId;

  @override
  String toString() =>
      'DshPermissionDenied: plugin $pluginId lacks $permission';
}

/// Permission-scoped host services handed to a plugin at load time. Every
/// accessor throws [DshPermissionDenied] unless the manifest declared it —
/// plugins can never reach capabilities they did not ask for.
class DshHostContext {
  DshHostContext({
    required this.pluginId,
    required this.permissions,
    Workspace? workspace,
    ShellExecutor? shell,
  })  : _workspace = workspace,
        _shell = shell;

  final String pluginId;
  final Set<String> permissions;
  final Workspace? _workspace;
  final ShellExecutor? _shell;

  void _require(String permission) {
    if (!permissions.contains(permission)) {
      throw DshPermissionDenied(permission, pluginId);
    }
  }

  /// Read-only workspace view; requires workspace.read. Writes additionally
  /// require workspace.write (enforced by [_WorkspaceView]).
  Workspace get workspace {
    _require(DshPermissions.workspaceRead);
    return _WorkspaceView(pluginId, permissions, _workspace!);
  }

  /// Shell access for terminal.execute plugins; null when the host has no
  /// executor (e.g. web harness). Throws [DshPermissionDenied] when the
  /// permission was not declared at all.
  ShellExecutor? get shellOrNull {
    if (!permissions.contains(DshPermissions.terminalExecute)) {
      throw DshPermissionDenied(DshPermissions.terminalExecute, pluginId);
    }
    return _shell;
  }

  /// Shell access that insists on a live executor.
  ShellExecutor get shell =>
      shellOrNull ?? (throw StateError('host did not provide a shell executor'));
}

/// Wraps the host workspace so a plugin can only write with the
/// workspace.write permission.
class _WorkspaceView implements Workspace {
  _WorkspaceView(this.pluginId, this.permissions, this._inner);

  final String pluginId;
  final Set<String> permissions;
  final Workspace _inner;

  void _requireWrite() {
    if (!permissions.contains(DshPermissions.workspaceWrite)) {
      throw DshPermissionDenied(DshPermissions.workspaceWrite, pluginId);
    }
  }

  @override
  Future<String?> readFile(String path) => _inner.readFile(path);

  @override
  Future<void> writeFile(String path, String content) async {
    _requireWrite();
    await _inner.writeFile(path, content);
  }

  @override
  Future<bool> deleteFile(String path) async {
    _requireWrite();
    return _inner.deleteFile(path);
  }

  @override
  Future<bool> exists(String path) => _inner.exists(path);

  @override
  Future<List<String>> listFiles([String prefix = '']) =>
      _inner.listFiles(prefix);

  @override
  Future<List<String>> searchFiles(String query) =>
      _inner.searchFiles(query);
}

/// One callable tool a plugin provides.
class DshTool {
  const DshTool({required this.decl, required this.call});

  final DshToolDecl decl;

  /// [args] are the decoded call arguments.
  final Future<String> Function(Map<String, dynamic> args) call;
}

/// A DSH plugin. Dart-runtime plugins implement this directly; shell-
/// runtime plugins get [ShellPlugin] for free.
abstract interface class DshPlugin {
  DshManifest get manifest;

  /// Tools this plugin provides. Populated after [onLoad].
  List<DshTool> get tools;

  Future<void> onLoad(DshHostContext context);
  Future<void> onEnable();
  Future<void> onDisable();
  Future<void> onUnload();
}

/// Declarative shell-runtime plugin: every manifest tool maps to a command
/// template; `{name}` placeholders are filled from call arguments. Commands
/// run through the same [ShellExecutor] and risk grading as the built-in
/// run_command tool — this is the DSH↔Shelly linkage (PHASE 16).
class ShellPlugin implements DshPlugin {
  ShellPlugin(this.manifest);

  @override
  final DshManifest manifest;

  ShellExecutor? _shell;

  @override
  late final List<DshTool> tools = [
    for (final decl in manifest.tools)
      DshTool(decl: decl, call: (args) => _invoke(decl, args)),
  ];

  @override
  Future<void> onLoad(DshHostContext context) async {
    _shell =
        context.permissions.contains(DshPermissions.terminalExecute)
            ? context.shellOrNull
            : null;
  }

  Future<String> _invoke(DshToolDecl decl, Map<String, dynamic> args) async {
    final shell = _shell;
    if (shell == null) {
      throw StateError(
          '${manifest.id} was not granted terminal.execute');
    }
    var command = decl.command!;
    args.forEach((key, value) {
      command = command.replaceAll('{$key}', value.toString());
    });
    // Declared risk drives the approval gate; the actual command still
    // goes through the host's critical-command block before running.
    final actualRisk = shell.classify(command);
    if (shell.policy.actionFor(actualRisk) == ShellAction.block) {
      return 'Error: command blocked by policy (risk: ${actualRisk.name})';
    }
    final result = await shell.execute(command);
    return 'risk=${decl.risk}\n${result.formatted()}';
  }

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<void> onUnload() async {
    _shell = null;
  }
}
