import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart' show themeModeProvider;
import '../../design/components/buttons.dart';
import '../../design/tokens.dart';
import '../../platform/platform_workspace.dart';

import '../../state/settings_store.dart';

/// Profile / settings page: model endpoint config with a masked API key,
/// theme switch and workspace overview.
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();
  bool _initialized = false;
  bool _saved = false;
  String? _workspaceNote;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  void _hydrate(ModelConfig config) {
    _initialized = true;
    _baseUrl.text = config.baseUrl;
    _apiKey.text = config.apiKey;
    _model.text = config.model;
  }

  Future<void> _checkWorkspace() async {
    final workspace = PlatformWorkspace();
    final has = await workspace.hasDirectory();
    if (!mounted) return;
    setState(() {
      _workspaceNote = has ? '已授权 SAF 工作区目录' : '尚未选择目录,点按右侧授权';
    });
  }

  Future<void> _pickWorkspace() async {
    final uri = await PlatformWorkspace().pickDirectory();
    if (!mounted) return;
    setState(() {
      _workspaceNote = uri == null ? '未选择目录' : '已授权 SAF 工作区目录';
    });
  }

  Future<void> _save() async {
    final store = ref.read(settingsStoreProvider).valueOrNull;
    if (store == null) return;
    await store.saveModelConfig(ModelConfig(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
    ));
    ref.invalidate(settingsStoreProvider);
    if (!mounted) return;
    setState(() => _saved = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final storeAsync = ref.watch(settingsStoreProvider);
    final config = storeAsync.valueOrNull?.modelConfig ?? const ModelConfig();
    if (!_initialized) {
      _hydrate(config);
      if (isAndroidHost) _checkWorkspace();
    }

    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text('我的',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: semantic.textPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _SectionHeader('模型配置', semantic),
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
                _Field(
                  controller: _baseUrl,
                  label: '接口地址(Base URL)',
                  hint: 'https://api.example.com/v1',
                  semantic: semantic,
                ),
                const SizedBox(height: AppSpacing.md),
                _Field(
                  controller: _apiKey,
                  label: 'API 密钥',
                  hint: 'sk-…',
                  obscure: true,
                  semantic: semantic,
                ),
                const SizedBox(height: AppSpacing.md),
                _Field(
                  controller: _model,
                  label: '模型名称',
                  hint: 'gpt-4o / deepseek-chat / …',
                  semantic: semantic,
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        config.isComplete ? '已接入自定义模型' : '未配置时使用演示模式',
                        style: TextStyle(
                            fontSize: 12,
                            color: config.isComplete
                                ? AppColors.success
                                : semantic.textTertiary),
                      ),
                    ),
                    if (_saved)
                      const Icon(Icons.check_circle,
                          size: 16, color: AppColors.success),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                GradientButton(
                  label: _saved ? '已保存' : '保存配置',
                  onPressed: _save,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _SectionHeader('外观', semantic),
          Container(
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.xs),
              leading: const Icon(Icons.dark_mode_outlined,
                  size: 20, color: AppColors.brandViolet),
              title: Text('深色模式',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: semantic.textPrimary)),
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('系统')),
                  ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                ],
                selected: {themeMode},
                onSelectionChanged: (selection) => ref
                    .read(themeModeProvider.notifier)
                    .state = selection.first,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _SectionHeader('关于', semantic),
          Container(
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  leading: const Icon(Icons.folder_outlined,
                      size: 20, color: AppColors.brandBlue),
                  title: Text('工作区',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: semantic.textPrimary)),
                  subtitle: Text(
                      isAndroidHost
                          ? (_workspaceNote ?? '检查工作区授权状态…')
                          : '内存工作区(演示) · Web 仅作开发调试',
                      style: TextStyle(
                          fontSize: 12, color: semantic.textTertiary)),
                  trailing: isAndroidHost
                      ? TextButton(
                          onPressed: _pickWorkspace,
                          child: const Text('选择目录'),
                        )
                      : null,
                ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  leading: const Icon(Icons.info_outline,
                      size: 20, color: AppColors.brandBlue),
                  title: Text('版本',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: semantic.textPrimary)),
                  subtitle: Text('Shelly Hermes 1.0.0 (1)',
                      style: TextStyle(
                          fontSize: 12, color: semantic.textTertiary)),
                ),
              ],
            ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(title,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: semantic.textTertiary)),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    required this.semantic,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final AppSemanticColors semantic;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: semantic.textTertiary)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: TextStyle(
              fontSize: 13.5,
              fontFamily: obscure ? 'monospace' : null,
              color: semantic.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 12.5, color: semantic.textTertiary),
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
      ],
    );
  }
}
