import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tools/registry.dart';
import '../../design/components/risk_chip.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';

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
          ...WorkspaceToolRegistry.specs.map((spec) {
            final level = levels[spec.name] ?? ToolPolicyLevel.confirm;
            return _ToolTile(spec: spec, level: level);
          }),
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
