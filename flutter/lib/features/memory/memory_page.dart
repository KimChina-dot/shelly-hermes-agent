import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hermes/forgetting.dart';
import '../../core/hermes/knowledge.dart';
import '../../design/tokens.dart';
import '../../state/hermes_provider.dart';

/// Hermes memory page (V2.0 B1): makes the agent's memory explainable —
/// what the ledger holds, how alive each entry is, and why forgetting
/// happens. Pure text ledger, no vector database.
class MemoryPage extends ConsumerWidget {
  const MemoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  '遗忘规则:7 天内被召回过为活跃;30 天内为冷却;'
                  '更久未用则过期清理(被召回 ≥3 次的条目受频次保护)。'
                  '整个账本保持在约 ${const ForgettingPolicy().maxLedgerTokens} token 预算内。',
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
            '${snapshot.entries.length} 条记忆 · 约 ${snapshot.totalTokens} token',
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white),
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
