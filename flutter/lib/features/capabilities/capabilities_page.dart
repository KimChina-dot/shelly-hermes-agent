import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/environment_checker.dart';
import '../../core/dsh/installer.dart';
import '../../core/dsh/plugin.dart';
import '../../core/dsh/tool_registry.dart' show DshTrust;
import '../../core/mcp/mcp_client.dart';
import '../../core/mcp/mcp_guard.dart';
import '../../core/tools/registry.dart';
import '../../design/components/risk_chip.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';
import '../../state/dsh_provider.dart';
import '../../state/plugin_repo.dart';
import '../../state/settings_store.dart';
import '../../platform/process_runner.dart';

/// Live file count of the active workspace, shown on the capability page.
final workspaceFileCountProvider = FutureProvider<int>((ref) async {
  final files = await ref.watch(workspaceProvider).listFiles();
  return files.length;
});

/// Capability page: every workspace tool with its description, risk level
/// and the approval policy level actually enforced by [ToolPolicy.standard].
class CapabilitiesPage extends ConsumerWidget {
  const CapabilitiesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final fileCount = ref.watch(workspaceFileCountProvider);
    final levels = ToolPolicy.standard.levels;

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text('能力',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: semantic.textPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Row(
            children: [
              Text('工作区工具',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: semantic.textTertiary)),
              const Spacer(),
              Text(fileCount.when(
                    data: (count) => '$count 个文件',
                    loading: () => '…',
                    error: (_, _) => '文件统计不可用',
                  ),
                  style: TextStyle(
                      fontSize: 12, color: semantic.textTertiary)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ...WorkspaceToolRegistry.workspaceSpecs.map((spec) {
            final level = levels[spec.name] ?? ToolPolicyLevel.confirm;
            return _ToolTile(spec: spec, level: level);
          }),
          const SizedBox(height: AppSpacing.lg),
          const _PluginSection(),
          const SizedBox(height: AppSpacing.lg),
          const _McpSection(),
          const SizedBox(height: AppSpacing.lg),
          const _BridgeSection(),
          const SizedBox(height: AppSpacing.lg),
          const _PluginRepoSection(),
          const SizedBox(height: AppSpacing.lg),
          const _EnvironmentSection(),
          const SizedBox(height: AppSpacing.lg),
          const _TrustSection(),
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.policy_outlined,
                    size: 18, color: AppColors.brandBlue),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '只读工具自动放行;写文件与补丁需要逐段确认;'
                    '未登记的工具一律先确认(fail closed)。',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: semantic.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// DSH plugin management (PHASE 22): install declarative plugins from a
/// manifest path inside the workspace, inspect their lifecycle and remove
/// them again. Installed plugins join every new task's tool surface.
class _PluginSection extends ConsumerStatefulWidget {
  const _PluginSection();

  @override
  ConsumerState<_PluginSection> createState() => _PluginSectionState();
}

class _PluginSectionState extends ConsumerState<_PluginSection> {
  final _manifestPath = TextEditingController(text: 'manifest.json');
  String? _note;
  bool _busy = false;

  @override
  void dispose() {
    _manifestPath.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final registry = ref.read(dshRegistryProvider);
    final workspace = ref.read(workspaceProvider);
    final installer = DshInstaller(registry: registry, workspace: workspace);
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final plugin = await installer.installFrom(_manifestPath.text.trim());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '已安装 ${plugin.manifest.id} v${plugin.manifest.version}'
            '(首次调用其工具时会请求确认)';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '安装失败:$error';
      });
    }
  }

  Future<void> _uninstall(String pluginId) async {
    final registry = ref.read(dshRegistryProvider);
    final workspace = ref.read(workspaceProvider);
    final installer = DshInstaller(registry: registry, workspace: workspace);
    try {
      await installer.uninstall(pluginId);
      if (!mounted) return;
      setState(() => _note = '已卸载 $pluginId');
    } catch (error) {
      if (!mounted) return;
      setState(() => _note = '卸载失败:$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final registry = ref.watch(dshRegistryProvider);
    final plugins = registry.list();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('插件(DSH)',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: semantic.textTertiary)),
        if (ref.watch(workspaceAuthorizedProvider).asData?.value == false)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Row(
              children: [
                Icon(Icons.folder_off_outlined,
                    size: 13, color: semantic.warning),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '工作区未授权:插件将装入演示沙箱,授权目录后需重新安装',
                    style: TextStyle(
                        fontSize: 11.5, color: semantic.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        for (final plugin in plugins)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.extension_outlined,
                    size: 18, color: AppColors.brandViolet),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${plugin.manifest.name} · ${plugin.manifest.id}',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: semantic.textPrimary)),
                      Text(
                        'v${plugin.manifest.version} · '
                        '${plugin.manifest.runtime} · '
                        '${plugin.tools.length} 个工具 · ${plugin.manifest.permissions.join(', ')}',
                        style: TextStyle(
                            fontSize: 11.5, color: semantic.textTertiary),
                      ),
                    ],
                  ),
                ),
                _LifecycleBadge(
                    lifecycle: registry.lifecycleOf(plugin.manifest.id) ??
                        DshLifecycle.unloaded),
                const SizedBox(width: AppSpacing.sm),
                if (registry.lifecycleOf(plugin.manifest.id) ==
                    DshLifecycle.enabled)
                  GestureDetector(
                    onTap: () => _uninstall(plugin.manifest.id),
                    child: Icon(Icons.delete_outline,
                        size: 18, color: semantic.textTertiary),
                  ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: semantic.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: semantic.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _manifestPath,
                style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: semantic.textPrimary),
                decoration: InputDecoration(
                  hintText: '工作区内的 manifest.json 路径',
                  hintStyle:
                      TextStyle(fontSize: 12, color: semantic.textTertiary),
                  isDense: true,
                  filled: true,
                  fillColor: semantic.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: semantic.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: semantic.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: const BorderSide(color: AppColors.brandBlue),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _busy ? null : _install,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_circle_outline, size: 16),
                label: const Text('安装插件', style: TextStyle(fontSize: 12.5)),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: semantic.border),
                ),
              ),
              if (_note != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(_note!,
                    style: TextStyle(
                        fontSize: 11.5, color: semantic.textSecondary)),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// Per-plugin-tool trust posture (PHASE 14 policy, surfaced here for
/// explainability): undecided tools show their fail-closed default.
class _TrustSection extends ConsumerWidget {
  const _TrustSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final registry = ref.watch(dshRegistryProvider);
    final trust = ref.watch(dshTrustProvider);
    final tools = [
      for (final plugin in registry.listEnabled())
        for (final tool in plugin.tools) tool.decl,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('插件工具信任',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: semantic.textTertiary)),
        const SizedBox(height: AppSpacing.sm),
        if (tools.isEmpty)
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: Text(
              '尚未启用任何插件工具。安装插件后,每个工具的信任状态会在这里展示。',
              style:
                  TextStyle(fontSize: 12, color: semantic.textTertiary),
            ),
          ),
        for (final decl in tools)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(decl.name,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace',
                              color: semantic.textPrimary)),
                      const SizedBox(height: 2),
                      Text(decl.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: semantic.textTertiary)),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                RiskChip(
                  level: switch (decl.risk) {
                    'high' => RiskLevel.high,
                    'medium' => RiskLevel.medium,
                    _ => RiskLevel.low,
                  },
                ),
                const SizedBox(width: AppSpacing.sm),
                _TrustBadge(trust: trust.trustFor(decl.name)),
              ],
            ),
          ),
        if (tools.isNotEmpty)
          Text(
            '未记录决定的工具默认封锁;首次调用转为询问,选择"始终允许"后免确认执行。',
            style: TextStyle(
                fontSize: 11.5, color: semantic.textTertiary),
          ),
      ],
    );
  }
}

class _TrustBadge extends StatelessWidget {
  const _TrustBadge({required this.trust});

  final DshTrust trust;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final (color, label) = switch (trust) {
      DshTrust.allowed => (semantic.success, '已信任'),
      DshTrust.ask => (semantic.warning, '首次询问'),
      DshTrust.blocked => (semantic.danger, '已封锁'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _LifecycleBadge extends StatelessWidget {
  const _LifecycleBadge({required this.lifecycle});

  final DshLifecycle lifecycle;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final (color, label) = switch (lifecycle) {
      DshLifecycle.enabled => (semantic.success, '启用中'),
      DshLifecycle.loaded ||
      DshLifecycle.registered ||
      DshLifecycle.disabled =>
        (semantic.warning, lifecycle.name),
      DshLifecycle.failed => (semantic.danger, '失败'),
      DshLifecycle.unloaded => (semantic.textTertiary, '未加载'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.spec, required this.level});

  final ToolSpec spec;
  final ToolPolicyLevel level;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final levelLabel = switch (level) {
      ToolPolicyLevel.allow => ('自动放行', semantic.success),
      ToolPolicyLevel.confirm => ('需要确认', semantic.warning),
      ToolPolicyLevel.deny => ('已禁用', semantic.danger),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(spec.name,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                        color: semantic.textPrimary)),
                const SizedBox(height: 2),
                Text(spec.description,
                    style: TextStyle(
                        fontSize: 12, color: semantic.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          RiskChip(
            level: switch (spec.risk) {
              'high' => RiskLevel.high,
              'medium' => RiskLevel.medium,
              _ => RiskLevel.low,
            },
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: levelLabel.$2.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Text(levelLabel.$1,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: levelLabel.$2)),
          ),
        ],
      ),
    );
  }
}

/// MCP connector management (PHASE 35): register Streamable-HTTP MCP
/// servers, probe their tool list and remove them again. Registered servers
/// expose their tools to every new task; each call needs approval.
///
/// PHASE 48: drift verdicts from the in-memory [McpGuardLedger] (seeded per
/// chat task before discovery) surface here as a warning card with
/// re-approval actions. The ledger is empty until a chat task or a
/// 测试连接 probe runs a discovery, so the card is simply absent before
/// that; both paths record fresh reports that this section picks up on its
/// next rebuild.
class _McpSection extends ConsumerStatefulWidget {
  const _McpSection();

  @override
  ConsumerState<_McpSection> createState() => _McpSectionState();
}

class _McpSectionState extends ConsumerState<_McpSection> {
  bool _probing = false;
  String? _probeNote;

  Future<SettingsStore?> _store() async {
    final async = ref.read(settingsStoreProvider);
    return async.valueOrNull ?? await ref.read(settingsStoreProvider.future);
  }

  Future<void> _addServer() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final token = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加 MCP 服务器'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '名称(如 github)'),
              ),
              TextField(
                controller: url,
                decoration: const InputDecoration(
                    labelText: '端点 URL', hintText: 'https://…/mcp'),
              ),
              TextField(
                controller: token,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Bearer 令牌(可选)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final serverName = name.text.trim();
    final serverUrl = url.text.trim();
    if (serverName.isEmpty || serverUrl.isEmpty) return;
    final store = await _store();
    if (store == null) return;
    final servers = [...store.loadMcpServers()];
    servers.add(McpServerConfig(
      id: 'mcp-${DateTime.now().millisecondsSinceEpoch}',
      name: serverName,
      url: serverUrl,
      token: token.text.trim(),
    ));
    await store.saveMcpServers(servers);
    if (mounted) setState(() {});
  }

  Future<void> _removeServer(McpServerConfig server) async {
    final store = await _store();
    if (store == null) return;
    await store.saveMcpServers([
      for (final entry in store.loadMcpServers())
        if (entry.id != server.id) entry,
    ]);
    if (mounted) setState(() {});
  }

  Future<void> _probeServer(McpServerConfig server) async {
    setState(() {
      _probing = true;
      _probeNote = null;
    });
    try {
      final tools = await McpClient().listTools(server);
      if (!mounted) return;
      setState(() {
        _probing = false;
        _probeNote = '${server.name}:发现 ${tools.length} 个工具';
      });
    } on McpException catch (error) {
      if (!mounted) return;
      setState(() {
        _probing = false;
        _probeNote = '${server.name}:${error.message}';
      });
    }
  }

  /// Supply-chain guard re-approval (PHASE 48): persists the catalog
  /// fingerprint the latest verdict was computed against as the newly
  /// approved fingerprint, mirrors the approval into the in-memory ledger
  /// (same table chat_session seeds from the store) and refreshes the card.
  /// Defensive: no report / empty fingerprint → nothing is written.
  Future<void> _retrust(String serverId) async {
    final report = McpGuardLedger.reportFor(serverId);
    if (report == null || report.fingerprint.isEmpty) return;
    final store = await _store();
    if (store == null) return;
    await store.saveMcpToolFingerprint(serverId, report.fingerprint);
    McpGuardLedger.seedApproved(store.loadMcpToolFingerprints());
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _retrustAll(List<String> serverIds) async {
    final store = await _store();
    if (store == null) return;
    for (final serverId in serverIds) {
      final report = McpGuardLedger.reportFor(serverId);
      if (report == null || report.fingerprint.isEmpty) continue;
      await store.saveMcpToolFingerprint(serverId, report.fingerprint);
    }
    McpGuardLedger.seedApproved(store.loadMcpToolFingerprints());
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final storeAsync = ref.watch(settingsStoreProvider);
    final servers = storeAsync.maybeWhen(
      data: (s) => s.loadMcpServers(),
      orElse: () => const <McpServerConfig>[],
    );
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.extension_rounded,
                  size: 18, color: AppColors.brandBlue),
              const SizedBox(width: AppSpacing.sm),
              Text('MCP 连接器',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: semantic.textPrimary)),
              const Spacer(),
              GestureDetector(
                onTap: _addServer,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: AppColors.brandBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add,
                          size: 13, color: AppColors.brandBlue),
                      const SizedBox(width: 2),
                      Text('添加服务器',
                          style: TextStyle(
                              fontSize: 11.5, color: AppColors.brandBlue)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('仅支持 Streamable HTTP;工具调用前都会请求审批。',
              style: TextStyle(fontSize: 11.5, color: semantic.textTertiary)),
          if (servers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text('尚未连接服务器',
                  style: TextStyle(
                      fontSize: 12.5, color: semantic.textTertiary)),
            )
          else
            for (final server in servers)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(server.name,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: semantic.textPrimary)),
                          Text(server.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: semantic.textTertiary)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '测试连接',
                      onPressed:
                          _probing ? null : () => _probeServer(server),
                      icon: _probing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.6))
                          : Icon(Icons.sync_alt,
                              size: 17, color: semantic.textSecondary),
                    ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: () => _removeServer(server),
                      icon: Icon(Icons.delete_outline_rounded,
                          size: 17, color: semantic.textSecondary),
                    ),
                  ],
                ),
              ),
          if (_probeNote != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(_probeNote!,
                  style: TextStyle(
                      fontSize: 11.5, color: semantic.textSecondary)),
            ),
          // Supply-chain guard (PHASE 48): surfaces rug-pull verdicts after
          // the server list. Defensive — an empty ledger renders nothing.
          if (_pendingGuardIds.isNotEmpty)
            _GuardWarningCard(
              pendingIds: _pendingGuardIds,
              onRetrust: _retrust,
              onRetrustAll: () => _retrustAll(_pendingGuardIds),
            ),
        ],
      ),
    );
  }

  /// Server ids whose latest discovery drifted from the approved catalog
  /// fingerprint (changed / removed). A server stops being pending once the
  /// approved fingerprint matches the drifted report's fingerprint again —
  /// `_retrust` seeds that approval into the ledger, and the next real
  /// discovery (`record`) refreshes the verdict either way, so a renewed
  /// drift after re-approval resurfaces here.
  List<String> get _pendingGuardIds => [
        for (final entry in McpGuardLedger.reports.entries)
          if (entry.value.requiresReapproval &&
              McpGuardLedger.approvedFor(entry.key) !=
                  entry.value.fingerprint)
            entry.key,
      ];
}

/// 「MCP 工具目录已变更」card: one row per server awaiting re-approval with
/// its verdict summary from the guard ledger, a per-server 重新信任 action
/// and a bulk 全部重新信任 action. Styled with the warning semantic color.
class _GuardWarningCard extends StatelessWidget {
  const _GuardWarningCard({
    required this.pendingIds,
    required this.onRetrust,
    required this.onRetrustAll,
  });

  final List<String> pendingIds;
  final ValueChanged<String> onRetrust;
  final VoidCallback onRetrustAll;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: semantic.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: semantic.warning.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16, color: semantic.warning),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text('MCP 工具目录已变更',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: semantic.warning)),
              ),
              GestureDetector(
                onTap: onRetrustAll,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: 3),
                  decoration: BoxDecoration(
                    color: semantic.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('全部重新信任',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: semantic.warning)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('以下服务器的工具目录与已批准的指纹不一致,重新发现前请确认来源可信。',
              style: TextStyle(
                  fontSize: 11, height: 1.5, color: semantic.textTertiary)),
          for (final serverId in pendingIds)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(serverId,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                                color: semantic.textPrimary)),
                        const SizedBox(height: 2),
                        Text(
                          McpGuardLedger.reportFor(serverId)?.summary ??
                              '工具目录指纹变化',
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              color: semantic.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  GestureDetector(
                    onTap: () => onRetrust(serverId),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm, vertical: 3),
                      decoration: BoxDecoration(
                        color: semantic.warning.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text('重新信任',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: semantic.warning)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 桌面桥接 (PHASE 45): configure the LAN PC that runs stdio MCP servers
/// behind `tool/mcp_bridge.dart`; the app consumes them as bridge tools.
class _BridgeSection extends ConsumerStatefulWidget {
  const _BridgeSection();

  @override
  ConsumerState<_BridgeSection> createState() => _BridgeSectionState();
}

class _BridgeSectionState extends ConsumerState<_BridgeSection> {
  McpBridgeConfig _config = const McpBridgeConfig();

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  Future<SettingsStore> _resolveStore() async {
    final cached = ref.read(settingsStoreProvider).valueOrNull;
    if (cached != null) return cached;
    return ref.read(settingsStoreProvider.future);
  }

  Future<void> _hydrate() async {
    final store = await _resolveStore();
    if (!mounted) return;
    setState(() => _config = store.loadMcpBridge());
  }

  Future<void> _edit() async {
    final url = TextEditingController(text: _config.baseUrl);
    final token = TextEditingController(text: _config.token);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('桌面 MCP 桥接'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '在电脑上运行 flutter/tool/mcp_bridge.dart 并加载 stdio 服务器配置,'
                '手机即可通过局域网调用这些工具。',
                style: TextStyle(fontSize: 12.5, height: 1.5),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: url,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: '桥接地址', hintText: 'http://192.168.x.x:8766'),
              ),
              TextField(
                controller: token,
                obscureText: true,
                decoration: const InputDecoration(labelText: '桥接令牌'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final store = await _resolveStore();
    await store.saveMcpBridge(McpBridgeConfig(
      baseUrl: url.text.trim(),
      token: token.text.trim(),
    ));
    ref.invalidate(settingsStoreProvider);
    final latest = await _resolveStore();
    if (!mounted) return;
    setState(() => _config = latest.loadMcpBridge());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_config.isComplete
          ? '桥接已保存,下次对话生效'
          : '桥接已清空')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.computer_outlined,
                  size: 18, color: semantic.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('桌面 MCP 桥接',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: semantic.textPrimary)),
              ),
              _BridgePill(configured: _config.isComplete, onTap: _edit),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _config.isComplete
                ? '已连接 ${_config.baseUrl}'
                : '未配置:在电脑上运行桥接后填入地址与令牌',
            style: TextStyle(
              fontSize: 12,
              color: _config.isComplete
                  ? semantic.textSecondary
                  : semantic.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BridgePill extends StatelessWidget {
  const _BridgePill({required this.configured, required this.onTap});

  final bool configured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        decoration: BoxDecoration(
          color: semantic.floating,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          configured ? '编辑' : '配置',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: semantic.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// 插件仓库 (PHASE 42): curated catalog of well-known MCP server presets.
/// One tap writes the preset's launch line into the MCP connector config
/// and remembers the id; the card flips to an 已安装 state that uninstalls
/// (removing both the id and the connector entry) when tapped again.
class _PluginRepoSection extends ConsumerStatefulWidget {
  const _PluginRepoSection();

  @override
  ConsumerState<_PluginRepoSection> createState() =>
      _PluginRepoSectionState();
}

class _PluginRepoSectionState extends ConsumerState<_PluginRepoSection> {
  String? _busyId;
  String? _note;

  Future<PluginRepoStore?> _repo() async {
    final async = ref.read(pluginRepoProvider);
    return async.valueOrNull ?? await ref.read(pluginRepoProvider.future);
  }

  Future<void> _toggle(PluginPreset preset, bool installed) async {
    setState(() {
      _busyId = preset.id;
      _note = null;
    });
    try {
      final repo = await _repo();
      if (repo == null) {
        if (!mounted) return;
        setState(() {
          _busyId = null;
          _note = '插件仓库暂不可用';
        });
        return;
      }
      final ok =
          installed ? await repo.uninstall(preset.id) : await repo.install(preset);
      if (!mounted) return;
      setState(() {
        _busyId = null;
        if (ok) {
          _note = installed
              ? '已卸载 ${preset.name},并从 MCP 连接器移除'
              : '已安装 ${preset.name}:已加入 MCP 连接器';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busyId = null;
        _note = installed ? '卸载失败:$error' : '安装失败:$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final repoAsync = ref.watch(pluginRepoProvider);
    final installedIds = repoAsync.maybeWhen(
      data: (repo) => repo.loadInstalledIds().toSet(),
      orElse: () => const <String>{},
    );
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.widgets_outlined,
                  size: 18, color: AppColors.brandViolet),
              const SizedBox(width: AppSpacing.sm),
              Text('插件仓库',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: semantic.textPrimary)),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('精选的本地 MCP 服务器预设,一键写入 MCP 连接器。',
              style: TextStyle(fontSize: 11.5, color: semantic.textTertiary)),
          for (final preset in pluginPresets)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: semantic.background,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: semantic.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(preset.name,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: semantic.textPrimary)),
                          const SizedBox(height: 2),
                          Text(preset.description,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: semantic.textSecondary)),
                          const SizedBox(height: 2),
                          Text(preset.launchLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                  color: semantic.textTertiary)),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _PresetPill(
                      presetId: preset.id,
                      installed: installedIds.contains(preset.id),
                      busy: _busyId == preset.id,
                      onTap: () => _toggle(preset, installedIds.contains(preset.id)),
                    ),
                  ],
                ),
              ),
            ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(_note!,
                  style: TextStyle(
                      fontSize: 11.5, color: semantic.textSecondary)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text('点「已安装」可卸载,并同步移除 MCP 连接器里的条目。',
                style: TextStyle(fontSize: 11.5, color: semantic.textTertiary)),
          ),
        ],
      ),
    );
  }
}

/// 添加 / 已安装 button state of one preset card; busy swaps the label
/// for a spinner while the store write settles.
class _PresetPill extends StatelessWidget {
  const _PresetPill({
    required this.presetId,
    required this.installed,
    required this.busy,
    required this.onTap,
  });

  final String presetId;
  final bool installed;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = installed
        ? Theme.of(context).extension<AppSemanticColors>()!.success
        : Theme.of(context).extension<AppSemanticColors>()!.textSecondary;
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: busy
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(installed ? Icons.check : Icons.add,
                      size: 12, color: color),
                  const SizedBox(width: 2),
                  Text(installed ? '已安装' : '添加',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: color)),
                ],
              ),
      ),
    );
  }
}

/// 运行环境 self-check (PHASE 36): one tap probes the workspace, shell,
/// model gateway and plugin surfaces and reports pass/warn/fail per row.
class _EnvironmentSection extends ConsumerStatefulWidget {
  const _EnvironmentSection();

  @override
  ConsumerState<_EnvironmentSection> createState() =>
      _EnvironmentSectionState();
}

class _EnvironmentSectionState extends ConsumerState<_EnvironmentSection> {
  List<EnvironmentCheck>? _results;
  bool _running = false;

  Future<void> _runChecks() async {
    setState(() {
      _running = true;
      _results = null;
    });
    final store = ref.read(settingsStoreProvider).valueOrNull;
    final config = store?.loadModelConfig();
    final checker = EnvironmentChecker(
      workspace: ref.read(workspaceProvider),
      processRunner: createProcessRunner(),
      baseUrl: config?.baseUrl ?? '',
      modelId: config?.model ?? '',
      apiKey: config?.apiKey ?? '',
      contextWindowTokens: config?.effectiveContextWindow ?? 0,
      dshToolCount: ref.read(dshToolsProvider).specs.length,
      mcpServerNames: [
        for (final server in store?.loadMcpServers() ?? const <McpServerConfig>[])
          server.name,
      ],
    );
    final results = await checker.run();
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.health_and_safety_outlined,
                  size: 18, color: AppColors.brandBlue),
              const SizedBox(width: AppSpacing.sm),
              Text('运行环境',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: semantic.textPrimary)),
              const Spacer(),
              GestureDetector(
                onTap: _running ? null : _runChecks,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: AppColors.brandBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: _running
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child:
                              CircularProgressIndicator(strokeWidth: 1.6))
                      : Text('一键自检',
                          style: TextStyle(
                              fontSize: 11.5, color: AppColors.brandBlue)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (_results == null && !_running)
            Text('检查工作区、Shell、模型网关与插件的可用状态。',
                style: TextStyle(
                    fontSize: 11.5, color: semantic.textTertiary)),
          if (_results != null)
            for (final check in _results!)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: switch (check.level) {
                          CheckLevel.ok => semantic.success,
                          CheckLevel.warn => semantic.warning,
                          CheckLevel.fail => semantic.danger,
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(check.label,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: semantic.textPrimary)),
                          Text(check.detail,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: semantic.textTertiary)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
