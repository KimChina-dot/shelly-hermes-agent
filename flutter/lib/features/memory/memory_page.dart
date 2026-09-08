import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hermes/forgetting.dart';
import '../../core/hermes/memory_settings.dart';
import '../../core/hermes/knowledge.dart';
import '../../core/memory/consolidation.dart';
import '../../core/memory/memory_store.dart';
import '../../design/tokens.dart';
import '../../state/hermes_provider.dart';
import '../../state/chat_session.dart';
import '../../state/settings_store.dart';
import 'memory_settings_page.dart';

/// Tiered view over the automatic long-term memory store (PHASE 47):
/// every [MemoryFact] with its current tier, reloaded on each mutation.
final memoryFactsProvider =
    FutureProvider.autoDispose<List<MemoryFact>>((ref) async {
  final store = await ref.watch(memoryStoreProvider.future);
  return store?.loadFacts() ?? const <MemoryFact>[];
});

/// Hermes memory page (V2.0 B1): makes the agent's memory explainable —
/// what the ledger holds, how alive each entry is, and why forgetting
/// happens. V2.1 adds the budget progress bar, manual upkeep and the
/// settings entry. PHASE 47 adds the Letta-style tier view: facts are
/// grouped into 核心/回忆/归档 with promote/demote controls and a
/// deterministic 整理记忆 pass backed by [MemoryConsolidator]. Pure text
/// ledger, no vector database.
class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key});

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  bool _upkeeping = false;
  UpkeepReport? _report;
  bool _consolidating = false;

  /// Cycle order for the per-fact tier control: 归档 → 回忆 → 核心 → 归档.
  /// One tap moves the fact one step up the hierarchy, wrapping back to
  /// archival from the top.
  static const List<MemoryTier> _tierCycle = [
    MemoryTier.archival,
    MemoryTier.recall,
    MemoryTier.core,
  ];

  MemoryTier _nextTier(MemoryTier tier) {
    final index = _tierCycle.indexOf(tier);
    if (index < 0) return MemoryTier.recall;
    // 归档→回忆、回忆→核心、核心→归档(the cycle wraps around).
    return _tierCycle[(index + 1) % _tierCycle.length];
  }

  Future<void> _promote(MemoryFact fact) async {
    final target = _nextTier(fact.tier);
    final store = await ref.read(memoryStoreProvider.future);
    if (store == null) return;
    await store.promote(fact.id, target);
    ref.invalidate(memoryFactsProvider);
  }

  Future<void> _runConsolidation() async {
    setState(() => _consolidating = true);
    try {
      final store = await ref.read(memoryStoreProvider.future);
      if (!mounted) return;
      if (store == null) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: const Text('记忆存储不可用,无法整理')),
        );
        return;
      }
      // Deterministic pass only — no summarizer, so nothing calls the model.
      final report = await MemoryConsolidator().consolidate(store);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '整理完成:合并 ${report.merged}、降级 ${report.demoted}、'
            '清理 ${report.evicted}、合成 ${report.synthesized}',
          ),
        ),
      );
      ref.invalidate(memoryFactsProvider);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('整理失败:$error')),
      );
    } finally {
      if (mounted) setState(() => _consolidating = false);
    }
  }

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
            onPressed: _consolidating ? null : _runConsolidation,
            child: _consolidating
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('整理记忆', style: TextStyle(fontSize: 13)),
          ),
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
              _SectionHeader('自动记忆', semantic),
              _TierFactsSection(
                factsAsync: ref.watch(memoryFactsProvider),
                semantic: semantic,
                onPromote: (fact) => _promote(fact),
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

/// Letta-style tier sections (核心/回忆/归档) over the automatic memory
/// facts, with per-tier counts and friendly hints for empty tiers.
class _TierFactsSection extends StatelessWidget {
  const _TierFactsSection({
    required this.factsAsync,
    required this.semantic,
    required this.onPromote,
  });

  final AsyncValue<List<MemoryFact>> factsAsync;
  final AppSemanticColors semantic;
  final ValueChanged<MemoryFact> onPromote;

  /// Render order mirrors the cycle: core on top, archival at the bottom.
  static const List<MemoryTier> _renderOrder = [
    MemoryTier.core,
    MemoryTier.recall,
    MemoryTier.archival,
  ];

  @override
  Widget build(BuildContext context) {
    return factsAsync.when(
      loading: () =>
          _TierEmptyHint(text: '正在读取分层记忆…', semantic: semantic),
      error: (error, _) =>
          _TierEmptyHint(text: '分层记忆读取失败:$error', semantic: semantic),
      data: (facts) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final tier in _renderOrder)
            _buildTier(
              tier,
              facts.where((fact) => fact.tier == tier).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildTier(MemoryTier tier, List<MemoryFact> facts) {
    final (label, color) = _tierChipStyle(tier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: AppSpacing.sm),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text('$label · ${facts.length}',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: semantic.textSecondary)),
            ],
          ),
        ),
        if (facts.isEmpty)
          _TierEmptyHint(text: _emptyHint(tier), semantic: semantic)
        else
          for (final fact in facts)
            _FactCard(
              fact: fact,
              semantic: semantic,
              onPromote: () => onPromote(fact),
            ),
      ],
    );
  }

  String _emptyHint(MemoryTier tier) => switch (tier) {
        MemoryTier.core =>
          '核心层还没有记忆。把最重要的长期偏好升级到这里,它们会始终注入上下文。',
        MemoryTier.recall => '回忆层暂时是空的。新学到的事实会先落在这里。',
        MemoryTier.archival => '归档层暂时是空的。久未使用的回忆会被整理降级到这里保存。',
      };
}

/// Chip label + accent color for each tier.
(String, Color) _tierChipStyle(MemoryTier tier) => switch (tier) {
      MemoryTier.core => ('核心', AppColors.brandViolet),
      MemoryTier.recall => ('回忆', AppColors.brandBlue),
      MemoryTier.archival => ('归档', AppColors.warning),
    };

/// One automatic memory fact with its tier chip and promote/demote control.
class _FactCard extends StatelessWidget {
  const _FactCard({
    required this.fact,
    required this.semantic,
    required this.onPromote,
  });

  final MemoryFact fact;
  final AppSemanticColors semantic;
  final VoidCallback onPromote;

  @override
  Widget build(BuildContext context) {
    final (label, color) = _tierChipStyle(fact.tier);
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, 2, AppSpacing.sm),
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
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
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
                    const SizedBox(width: AppSpacing.sm),
                    Text('记录于 ${_formatDate(fact.createdAt)}',
                        style: TextStyle(
                            fontSize: 10.5, color: semantic.textTertiary)),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(fact.text,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: semantic.textPrimary)),
              ],
            ),
          ),
          IconButton(
            tooltip: '调整层级',
            onPressed: onPromote,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.upgrade_rounded,
                size: 18, color: semantic.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// Quiet placeholder for an empty or failed tier.
class _TierEmptyHint extends StatelessWidget {
  const _TierEmptyHint({required this.text, required this.semantic});

  final String text;
  final AppSemanticColors semantic;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, height: 1.6, color: semantic.textTertiary)),
    );
  }
}

String _formatDate(DateTime time) =>
    '${time.year}/${time.month}/${time.day}';
