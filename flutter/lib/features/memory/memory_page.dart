import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hermes/forgetting.dart';
import '../../core/hermes/memory_settings.dart';
import '../../core/hermes/knowledge.dart';
import '../../design/tokens.dart';
import '../../state/hermes_provider.dart';
import '../../state/chat_session.dart';
import '../../state/settings_store.dart';
import 'memory_settings_page.dart';

/// Hermes memory page (V2.0 B1): makes the agent's memory explainable —
/// what the ledger holds, how alive each entry is, and why forgetting
/// happens. V2.1 adds the budget progress bar, manual upkeep and the
/// settings entry. Pure text ledger, no vector database.
class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key});

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  bool _upkeeping = false;
  UpkeepReport? _report;

  Future<void> _runUpkeep() async {
    setState(() {
      _upkeeping = true;
      _report = null;
    });
    try {
      final workspace = ref.read(workspaceProvider);
      final project =
          await ref.read(workspaceManagerProvider).detectProject();
      final settings =
          ref.read(settingsStoreProvider).valueOrNull?.loadMemorySettings() ??
              const MemorySettings();
      final report = await runUpkeepWith(
        workspace: workspace,
        project: project.name,
        settings: settings,
      );
      if (!mounted) return;
      setState(() {
        _upkeeping = false;
        _report = report;
      });
      ref.invalidate(hermesLedgerProvider);
    } catch (error) {
      if (!mounted) return;
      setState(() => _upkeeping = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('整理失败:$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final snapshotAsync = ref.watch(hermesLedgerProvider);

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text('记忆(Hermes)',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: semantic.textPrimary)),
        actions: [
          TextButton(
            onPressed: _upkeeping ? null : _runUpkeep,
            child: _upkeeping
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('立即整理', style: TextStyle(fontSize: 13)),
          ),
          IconButton(
            tooltip: '记忆参数',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const MemorySettingsPage()));
              if (mounted) ref.invalidate(hermesLedgerProvider);
            },
            icon: const Icon(Icons.tune, size: 21),
          ),
        ],
      ),
      body: snapshotAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text('记忆账本读取失败:$error',
              style: TextStyle(fontSize: 13, color: AppColors.danger)),
        ),
        data: (snapshot) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(hermesLedgerProvider),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _StateCard(snapshot: snapshot),
              if (_report != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _ReportCard(report: _report!),
              ],
              const SizedBox(height: AppSpacing.lg),
              _SectionHeader('账本条目', semantic),
              if (snapshot.entries.isEmpty)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: semantic.card,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: semantic.border),
                  ),
                  child: Text(
                    '还没有记住任何东西。完成一次对话后,'
                    '值得沉淀的经验会自动写入这里的账本。',
                    style:
                        TextStyle(fontSize: 12.5, color: semantic.textTertiary),
                  ),
                ),
              for (final entry in snapshot.entries)
                _EntryCard(
                  entry: entry,
                  vitality: snapshot.vitalityOf(entry),
                ),
              const SizedBox(height: AppSpacing.lg),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: semantic.card,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: semantic.border),
                ),
                child: Text(
                  '遗忘规则:${snapshot.settings.activeDays} 天内被召回过为活跃;'
                  '${snapshot.settings.coolingDays} 天内为冷却;更久未用则过期清理'
                  '(被召回 ≥${snapshot.settings.frequencyFloor} 次的条目受频次保护)。'
                  '整个账本保持在约 ${snapshot.settings.maxLedgerTokens} token 预算内,'
                  '单次召回注入约 ${snapshot.settings.recallTokens} token。'
                  '参数可在右上角调整。',
                  style: TextStyle(
                      fontSize: 12, height: 1.6, color: semantic.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({required this.snapshot});

  final HermesLedgerSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final stats = <(String, int)>[
      ('活跃', snapshot.countOf(KnowledgeVitality.active)),
      ('冷却', snapshot.countOf(KnowledgeVitality.cooling)),
      ('过期', snapshot.countOf(KnowledgeVitality.expired)),
    ];
    final budget = snapshot.settings.maxLedgerTokens;
    final ratio = budget <= 0 ? 0.0 : (snapshot.totalTokens / budget).clamp(0.0, 1.0);
    final nearBudget = ratio > 0.8;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: AppColors.brandGradient),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${snapshot.entries.length} 条记忆 · 约 ${snapshot.totalTokens} / $budget token',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white),
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 5,
              backgroundColor: Colors.white.withValues(alpha: 0.25),
              valueColor: AlwaysStoppedAnimation<Color>(
                  nearBudget ? AppColors.warning : Colors.white),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (final (label, count) in stats) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('$label $count',
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final UpkeepReport report;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
      ),
      child: Text(
        '整理完成:归并 ${report.mergedEntries} 组近似条目 · '
        '吸收 ${report.absorbedEntries} 条重复 · '
        '清理 ${report.droppedEntries} 条(过期或超出预算),'
        '剩余 ${report.remainingEntries} 条。',
        style: TextStyle(
            fontSize: 12, height: 1.6, color: semantic.textSecondary),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, required this.vitality});

  final KnowledgeEntry entry;
  final KnowledgeVitality vitality;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final (color, label) = switch (vitality) {
      KnowledgeVitality.active => (AppColors.success, '活跃'),
      KnowledgeVitality.cooling => (AppColors.warning, '冷却'),
      KnowledgeVitality.expired => (AppColors.danger, '过期'),
    };
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
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
              _Chip(label: entry.category),
              const SizedBox(width: AppSpacing.sm),
              _Chip(label: entry.source),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(entry.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13, height: 1.5, color: semantic.textPrimary)),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '召回 ${entry.frequency} 次 · 最近 ${_formatDate(entry.lastTriggeredAt)}'
            '${entry.project.isEmpty ? '' : ' · ${entry.project}'}',
            style: TextStyle(fontSize: 11.5, color: semantic.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.brandViolet.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppColors.brandViolet)),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, this.semantic);

  final String title;
  final AppSemanticColors semantic;

  @override
  Widget build(BuildContext context) {
    return Text(title,
        style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: semantic.textTertiary));
  }
}

String _formatDate(DateTime time) =>
    '${time.year}/${time.month}/${time.day}';
