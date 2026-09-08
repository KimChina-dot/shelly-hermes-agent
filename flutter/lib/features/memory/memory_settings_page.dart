import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/hermes/memory_settings.dart';
import '../../design/tokens.dart';
import '../../state/settings_store.dart';

/// Memory tuning page (V2.1 PHASE 26): storage budget (ledger size and
/// forgetting windows) vs recall budget (what gets injected per round).
/// Changes take effect on the next upkeep run, not retroactively.
class MemorySettingsPage extends ConsumerStatefulWidget {
  const MemorySettingsPage({super.key});

  @override
  ConsumerState<MemorySettingsPage> createState() =>
      _MemorySettingsPageState();
}

class _MemorySettingsPageState extends ConsumerState<MemorySettingsPage> {
  MemorySettings? _draft;
  bool _saved = false;

  // PHASE 47: tier upkeep knobs, persisted as plain int prefs with the
  // same keys the consolidator reads. Stored via SharedPreferences
  // directly (outside the Hermes [MemorySettings] blob) and saved
  // immediately on change — no extra save button.
  static const _recallAgeDaysKey = 'shelly.memory.recallAgeDays';
  static const _archivalCapKey = 'shelly.memory.archivalCap';
  static const _defaultRecallAgeDays = 45;
  static const _defaultArchivalCap = 300;

  int _recallAgeDays = _defaultRecallAgeDays;
  int _archivalCap = _defaultArchivalCap;

  @override
  void initState() {
    super.initState();
    _loadTierSettings();
  }

  Future<void> _loadTierSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _recallAgeDays =
            prefs.getInt(_recallAgeDaysKey) ?? _defaultRecallAgeDays;
        _archivalCap = prefs.getInt(_archivalCapKey) ?? _defaultArchivalCap;
      });
    } on Exception {
      // SharedPreferences unavailable: keep the defaults for this session.
    }
  }

  Future<void> _saveTierInt(String key, int value) async {
    setState(() {
      if (key == _recallAgeDaysKey) {
        _recallAgeDays = value;
      } else if (key == _archivalCapKey) {
        _archivalCap = value;
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, value);
    } on Exception {
      // Best-effort persistence; the slider state stays for this session.
    }
  }

  MemorySettings get _settings =>
      _draft ??
      ref.read(settingsStoreProvider).valueOrNull?.loadMemorySettings() ??
      const MemorySettings();

  void _update(MemorySettings Function(MemorySettings) transform) {
    setState(() {
      _draft = transform(_settings);
      _saved = false;
    });
  }

  Future<void> _save() async {
    final store = ref.read(settingsStoreProvider).valueOrNull;
    if (store == null || _draft == null) return;
    await store.saveMemorySettings(_draft!);
    ref.invalidate(settingsStoreProvider);
    if (!mounted) return;
    setState(() => _saved = true);
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final s = _settings;

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text('记忆参数',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: semantic.textPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _SectionHeader('存储预算', semantic),
          const SizedBox(height: AppSpacing.sm),
          _Card(semantic: semantic, children: [
            _SliderTile(
              label: '账本 token 预算',
              description: '整个知识账本的目标大小,超出时遗忘清理',
              value: s.maxLedgerTokens.toDouble(),
              min: 500,
              max: 50000,
              divisions: 99,
              display: '${s.maxLedgerTokens} token',
              semantic: semantic,
              onChanged: (v) => _update(
                  (s) => s.copyWith(maxLedgerTokens: v.round())),
            ),
            _SliderTile(
              label: '活跃窗口',
              description: '该天数内被召回过的条目视为活跃',
              value: s.activeDays.toDouble(),
              min: 1,
              max: 60,
              divisions: 59,
              display: '${s.activeDays} 天',
              semantic: semantic,
              onChanged:
                  (v) => _update((s) => s.copyWith(activeDays: v.round())),
            ),
            _SliderTile(
              label: '冷却窗口',
              description: '该天数内被召回过的条目视为冷却,更久则过期',
              value: s.coolingDays.toDouble(),
              min: 1,
              max: 365,
              divisions: 364,
              display: '${s.coolingDays} 天',
              semantic: semantic,
              onChanged:
                  (v) => _update((s) => s.copyWith(coolingDays: v.round())),
            ),
            _SliderTile(
              label: '频次保护',
              description: '被召回达到该次数的条目不会因时间过期',
              value: s.frequencyFloor.toDouble(),
              min: 1,
              max: 20,
              divisions: 19,
              display: '≥${s.frequencyFloor} 次',
              semantic: semantic,
              onChanged: (v) =>
                  _update((s) => s.copyWith(frequencyFloor: v.round())),
            ),
            _SliderTile(
              label: '自动记录上限',
              description: '自动沉淀的经验条数达到上限后暂停采集',
              value: s.maxAutoEntries.toDouble(),
              min: 10,
              max: 1000,
              divisions: 99,
              display: '${s.maxAutoEntries} 条',
              semantic: semantic,
              onChanged: (v) =>
                  _update((s) => s.copyWith(maxAutoEntries: v.round())),
            ),
          ]),
          const SizedBox(height: AppSpacing.lg),
          _SectionHeader('召回预算', semantic),
          const SizedBox(height: AppSpacing.sm),
          _Card(semantic: semantic, children: [
            _SliderTile(
              label: '召回条数',
              description: '每轮任务开始前注入上下文的记忆条数',
              value: s.recallEntries.toDouble(),
              min: 1,
              max: 30,
              divisions: 29,
              display: '${s.recallEntries} 条',
              semantic: semantic,
              onChanged: (v) =>
                  _update((s) => s.copyWith(recallEntries: v.round())),
            ),
            _SliderTile(
              label: '召回 token 预算',
              description: '单次召回注入上下文的 token 上限',
              value: s.recallTokens.toDouble(),
              min: 100,
              max: 8000,
              divisions: 79,
              display: '${s.recallTokens} token',
              semantic: semantic,
              onChanged: (v) =>
                  _update((s) => s.copyWith(recallTokens: v.round())),
            ),
          ]),
          const SizedBox(height: AppSpacing.lg),
          _SectionHeader('记忆整理', semantic),
          const SizedBox(height: AppSpacing.sm),
          _Card(semantic: semantic, children: [
            _SliderTile(
              key: const Key('recall-age-days-slider'),
              label: '回忆老化天数',
              description: '回忆层条目超过该天数未被召回,整理时降级为归档',
              value: _recallAgeDays.toDouble(),
              min: 1,
              max: 180,
              divisions: 179,
              display: '$_recallAgeDays 天',
              semantic: semantic,
              onChanged: (v) => _saveTierInt(_recallAgeDaysKey, v.round()),
            ),
            _SliderTile(
              key: const Key('archival-cap-slider'),
              label: '归档容量上限',
              description: '归档层最多保留的条数,超出时整理会清理最旧的条目',
              value: _archivalCap.toDouble(),
              min: 20,
              max: 1000,
              divisions: 98,
              display: '$_archivalCap 条',
              semantic: semantic,
              onChanged: (v) => _saveTierInt(_archivalCapKey, v.round()),
            ),
          ]),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: _draft == null ? null : _save,
            icon: _saved
                ? const Icon(Icons.check_rounded, size: 17)
                : const Icon(Icons.save_outlined, size: 17),
            label: Text(_saved ? '已保存' : '保存'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '预算与分层参数立即持久化:预算改动生效于下一次记忆整理与召回,'
            '整理参数生效于下一次「整理记忆」,都不会改动已有条目。',
            style: TextStyle(
                fontSize: 11.5, color: semantic.textTertiary),
          ),
        ],
      ),
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

class _Card extends StatelessWidget {
  const _Card({required this.children, required this.semantic});

  final List<Widget> children;
  final AppSemanticColors semantic;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Column(children: children),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    super.key,
    required this.label,
    required this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.semantic,
    required this.onChanged,
  });

  final String label;
  final String description;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final AppSemanticColors semantic;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: semantic.textPrimary)),
              ),
              Text(display,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.brandBlue)),
            ],
          ),
          Text(description,
              style: TextStyle(fontSize: 11.5, color: semantic.textTertiary)),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
