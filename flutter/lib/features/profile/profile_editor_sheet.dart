import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent_profile.dart';
import '../../design/tokens.dart';
import '../../state/settings_store.dart';

/// Opens the profile editor. Presets are copied into a user-owned profile
/// (V2.1 PHASE 27); custom profiles are edited in place and can be deleted.
Future<void> showProfileEditor(
  BuildContext context,
  WidgetRef ref, {
  AgentProfile? profile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ProfileEditorSheet(profile: profile),
  );
}

class _ProfileEditorSheet extends ConsumerStatefulWidget {
  const _ProfileEditorSheet({this.profile});

  final AgentProfile? profile;

  @override
  ConsumerState<_ProfileEditorSheet> createState() =>
      _ProfileEditorSheetState();
}

class _ProfileEditorSheetState extends ConsumerState<_ProfileEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _maxRounds;
  late final TextEditingController _maxToolCalls;
  late bool _autoCapture;
  late final bool _editingPreset;
  late final bool _isCustom;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _editingPreset = profile?.isPreset ?? false;
    _isCustom = profile != null && !_editingPreset;
    _name = TextEditingController(
        text: _editingPreset ? '${profile!.name}(自定义)' : (profile?.name ?? ''));
    _prompt = TextEditingController(text: profile?.systemPrompt ?? '');
    _maxRounds = TextEditingController(text: '${profile?.maxRounds ?? 16}');
    _maxToolCalls =
        TextEditingController(text: '${profile?.maxToolCalls ?? 32}');
    _autoCapture = profile?.autoCapture ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _maxRounds.dispose();
    _maxToolCalls.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final store = ref.read(settingsStoreProvider).valueOrNull;
    if (store == null) return;
    final name = _name.text.trim();
    final maxRounds = int.tryParse(_maxRounds.text.trim()) ?? 16;
    final maxToolCalls = int.tryParse(_maxToolCalls.text.trim()) ?? 32;
    if (name.isEmpty) return;

    AgentProfile edited(AgentProfile base) => base.copyWith(
          name: name,
          systemPrompt: _prompt.text.trim(),
          autoCapture: _autoCapture,
          maxRounds: maxRounds.clamp(1, 200),
          maxToolCalls: maxToolCalls.clamp(1, 500),
        );

    final profiles = store.loadProfiles();
    if (widget.profile == null) {
      // New profile.
      final created = edited(AgentProfile(
        id: 'profile-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
      ));
      await store.saveProfiles([...profiles, created]);
      await store.saveActiveProfileId(created.id);
    } else if (_editingPreset) {
      // Presets stay intact; the edit lands in a user-owned copy.
      final copy = edited(
          widget.profile!.asEditableCopy(newId: 'profile-${DateTime.now().millisecondsSinceEpoch}'));
      await store.saveProfiles([...profiles, copy]);
      await store.saveActiveProfileId(copy.id);
    } else {
      // Custom profile: update in place.
      final updated = profiles
          .map((p) => p.id == widget.profile!.id ? edited(p) : p)
          .toList();
      await store.saveProfiles(updated);
    }
    ref.invalidate(settingsStoreProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final store = ref.read(settingsStoreProvider).valueOrNull;
    if (store == null || !_isCustom) return;
    final deleted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除档案'),
        content: Text('将删除「${_name.text.trim()}」,使用它的会话会回落到第一个预设。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (deleted != true) return;
    await store.saveProfiles(store
        .loadProfiles()
        .where((p) => p.id != widget.profile!.id)
        .toList());
    if (store.loadActiveProfileId() == widget.profile!.id) {
      await store.saveActiveProfileId(null);
    }
    ref.invalidate(settingsStoreProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: semantic.card,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.profile == null
                          ? '新建档案'
                          : (_editingPreset ? '复制并编辑预设' : '编辑档案'),
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: semantic.textPrimary),
                    ),
                  ),
                  if (_isCustom)
                    IconButton(
                      tooltip: '删除档案',
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: AppColors.danger),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _EditorField(
                controller: _name,
                label: '档案名称',
                hint: '例如 深度调试助手',
                maxLength: 40,
                semantic: semantic,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.md),
              _EditorField(
                controller: _prompt,
                label: '人设提示词(系统消息)',
                hint: '这段话会作为系统消息开启每个新任务',
                maxLength: 2000,
                maxLines: 4,
                semantic: semantic,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: _EditorField(
                      controller: _maxRounds,
                      label: '最大轮数(1–200)',
                      hint: '16',
                      semantic: semantic,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _EditorField(
                      controller: _maxToolCalls,
                      label: '工具调用上限(1–500)',
                      hint: '32',
                      semantic: semantic,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('自动记录经验',
                      style: TextStyle(
                          fontSize: 13.5, color: semantic.textPrimary)),
                  subtitle: Text('完成的任务会沉淀进 Hermes 记忆账本',
                      style: TextStyle(
                          fontSize: 11.5, color: semantic.textTertiary)),
                  value: _autoCapture,
                  onChanged: (v) => setState(() => _autoCapture = v),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: _name.text.trim().isEmpty ? null : _save,
                icon: const Icon(Icons.check_rounded, size: 17),
                label: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorField extends StatelessWidget {
  const _EditorField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.semantic,
    this.maxLength,
    this.maxLines = 1,
    this.keyboardType,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final AppSemanticColors semantic;
  final int? maxLength;
  final int maxLines;
  final TextInputType? keyboardType;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: semantic.textTertiary)),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: controller,
          maxLength: maxLength,
          maxLines: maxLines,
          keyboardType: keyboardType,
          onChanged: onChanged == null ? null : (_) => onChanged!(),
          style: TextStyle(fontSize: 13.5, color: semantic.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            counterText: '',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }
}
