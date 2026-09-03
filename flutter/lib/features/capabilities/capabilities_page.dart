import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/dsh/installer.dart';
import '../../core/dsh/plugin.dart';
import '../../core/dsh/tool_registry.dart' show DshTrust;
import '../../core/tools/registry.dart';
import '../../design/components/risk_chip.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';
import '../../state/dsh_provider.dart';

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
    final (color, label) = switch (trust) {
      DshTrust.allowed => (AppColors.success, '已信任'),
      DshTrust.ask => (AppColors.warning, '首次询问'),
      DshTrust.blocked => (AppColors.danger, '已封锁'),
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
      DshLifecycle.enabled => (AppColors.success, '启用中'),
      DshLifecycle.loaded ||
      DshLifecycle.registered ||
      DshLifecycle.disabled =>
        (AppColors.warning, lifecycle.name),
      DshLifecycle.failed => (AppColors.danger, '失败'),
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
      ToolPolicyLevel.allow => ('自动放行', AppColors.success),
      ToolPolicyLevel.confirm => ('需要确认', AppColors.warning),
      ToolPolicyLevel.deny => ('已禁用', AppColors.danger),
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
