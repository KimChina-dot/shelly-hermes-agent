import 'package:flutter/material.dart';

import '../../design/components/risk_chip.dart';
import '../../design/tokens.dart';

/// Capability catalog: the workspace toolset the agent may call, each with
/// its approval policy so the user can see the trust boundary at a glance.
class CapabilitiesPage extends StatelessWidget {
  const CapabilitiesPage({super.key});

  static const _tools = <_ToolInfo>[
    _ToolInfo(Icons.read_more_rounded, 'read_file', '读取工作区文件内容', RiskLevel.low),
    _ToolInfo(Icons.list_rounded, 'list_files', '列出目录与文件树', RiskLevel.low),
    _ToolInfo(Icons.search_rounded, 'search_files', '按名称或内容搜索文件', RiskLevel.low),
    _ToolInfo(Icons.article_outlined, 'exists', '检查文件是否存在', RiskLevel.low),
    _ToolInfo(Icons.edit_note_rounded, 'write_file', '写入或覆盖文件', RiskLevel.medium),
    _ToolInfo(Icons.difference_outlined, 'apply_patch', '按 hunk 应用代码补丁,逐段审批', RiskLevel.high),
  ];

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text(
          '能力',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: semantic.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          Text(
            '工作区工具',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: semantic.textTertiary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          ..._tools.map((t) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: _ToolCard(info: t),
              )),
        ],
      ),
    );
  }
}

class _ToolInfo {
  const _ToolInfo(this.icon, this.name, this.description, this.risk);

  final IconData icon;
  final String name;
  final String description;
  final RiskLevel risk;
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.info});

  final _ToolInfo info;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              color: semantic.floating,
            ),
            child: Icon(info.icon, size: 20, color: semantic.textSecondary),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.name,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: AppColors.brandBlue,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  info.description,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: semantic.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          RiskChip(level: info.risk),
        ],
      ),
    );
  }
}
