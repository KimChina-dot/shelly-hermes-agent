import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart' show themeModeProvider;
import '../../core/agent_profile.dart';
import '../../core/gateway/model_discovery.dart';
import '../../core/gateway/openai_gateway.dart' show GatewayException;
import '../../core/gateway/providers.dart';
import '../../design/components/buttons.dart';
import '../../design/tokens.dart';
import '../../features/memory/memory_page.dart';
import '../../platform/platform_workspace.dart';
import '../../state/chat_session.dart'
    show workspaceAuthorizedProvider, workspaceProvider;

import '../../state/settings_store.dart';

/// Profile / settings page: model endpoint config with a masked API key,
/// provider presets, model discovery, agent profiles, theme switch and
/// workspace overview.
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
  bool _discovering = false;
  String? _workspaceNote;
  String? _discoveryNote;
  bool _testing = false;
  String? _testNote;
  String _providerId = 'custom';
  String? _activeProfileId;

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
    _providerId = _matchProvider(config.baseUrl);
  }

  String _matchProvider(String baseUrl) {
    for (final preset in llmProviderPresets) {
      if (preset.defaultBaseUrl.isNotEmpty && preset.defaultBaseUrl == baseUrl) {
        return preset.id;
      }
    }
    return 'custom';
  }

  Future<void> _checkWorkspace() async {
    // Use the shared resilient instance so the note matches the actual
    // workspace routing (SAF once granted, sandbox before that).
    final workspace = ref.read(workspaceProvider);
    if (workspace is! ResilientWorkspace) {
      if (!mounted) return;
      setState(() => _workspaceNote = '内存工作区(演示) · Web 仅作开发调试');
      return;
    }
    await workspace.refreshAuthorization();
    if (!mounted) return;
    setState(() {
      _workspaceNote = workspace.authorized.value
          ? '已授权 SAF 工作区目录'
          : '尚未选择目录,点按右侧授权';
    });
  }

  Future<void> _pickWorkspace() async {
    final workspace = ref.read(workspaceProvider);
    if (workspace is! ResilientWorkspace) return;
    final uri = await workspace.pickDirectory();
    ref.invalidate(workspaceAuthorizedProvider);
    if (!mounted) return;
    setState(() {
      _workspaceNote = uri == null ? '未选择目录' : '已授权 SAF 工作区目录';
    });
  }

  Future<void> _testConnection() async {
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) {
      setState(() => _testNote = '请先填写接口地址和模型名称');
      return;
    }
    setState(() {
      _testing = true;
      _testNote = null;
    });
    try {
      final latency = await ModelDiscovery().testConnection(
        baseUrl: baseUrl,
        model: model,
        apiKey: _apiKey.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testNote = '连接正常 · ${latency.inMilliseconds} ms';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testNote = _humanizeGatewayError(error);
      });
    }
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

  void _applyPreset(LlmProviderPreset preset) {
    setState(() {
      _providerId = preset.id;
      if (preset.defaultBaseUrl.isNotEmpty) {
        _baseUrl.text = preset.defaultBaseUrl;
      }
      _discoveryNote = null;
    });
  }

  Future<void> _discoverModels() async {
    final baseUrl = _baseUrl.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _discoveryNote = '请先填写接口地址');
      return;
    }
    setState(() {
      _discovering = true;
      _discoveryNote = null;
    });
    try {
      final models = await ModelDiscovery().listModels(
        baseUrl: baseUrl,
        apiKey: _apiKey.text.trim(),
      );
      if (!mounted) return;
      setState(() => _discovering = false);
      if (models.isEmpty) {
        setState(() => _discoveryNote = '端点未返回任何模型');
        return;
      }
      final selected = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Theme.of(context).extension<AppSemanticColors>()!.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text('选择模型(${models.length})',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              for (final model in models)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.memory_outlined, size: 18),
                  title: Text(model.id, style: const TextStyle(fontSize: 13.5)),
                  onTap: () => Navigator.of(context).pop(model.id),
                ),
            ],
          ),
        ),
      );
      if (selected != null) setState(() => _model.text = selected);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _discovering = false;
        _discoveryNote = '获取失败:$error';
      });
    }
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
    final store = storeAsync.valueOrNull;
    final profiles = store?.loadProfiles() ?? agentProfilePresets;
    _activeProfileId ??=
        store?.loadActiveProfileId() ?? agentProfilePresets.first.id;

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
          _SectionHeader('Agent 档案', semantic),
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
                for (final profile in profiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      onTap: () async {
                        setState(() => _activeProfileId = profile.id);
                        if (store != null) {
                          await store.saveActiveProfileId(profile.id);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: profile.id == _activeProfileId
                              ? semantic.background
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(
                              color: profile.id == _activeProfileId
                                  ? AppColors.brandBlue
                                  : semantic.border),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              profile.id == _activeProfileId
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 16,
                              color: profile.id == _activeProfileId
                                  ? AppColors.brandBlue
                                  : semantic.textTertiary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(profile.name,
                                      style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600,
                                          color: semantic.textPrimary)),
                                  Text(
                                    profile.autoCapture
                                        ? '记录经验 · ${profile.maxRounds} 轮'
                                        : '不记录经验 · ${profile.maxRounds} 轮',
                                    style: TextStyle(
                                        fontSize: 11.5,
                                        color: semantic.textTertiary),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
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
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final preset in llmProviderPresets)
                      ChoiceChip(
                        label: Text(preset.label,
                            style: TextStyle(
                                fontSize: 12,
                                color: preset.id == _providerId
                                    ? Colors.white
                                    : semantic.textSecondary)),
                        selected: preset.id == _providerId,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        selectedColor: AppColors.brandBlue,
                        backgroundColor: semantic.background,
                        side: BorderSide(
                            color: preset.id == _providerId
                                ? AppColors.brandBlue
                                : semantic.border),
                        onSelected: (_) => _applyPreset(preset),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
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
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _discovering ? null : _discoverModels,
                      icon: _discovering
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_download_outlined,
                              size: 16),
                      label: const Text('获取模型列表',
                          style: TextStyle(fontSize: 12.5)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: semantic.border),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _testConnection,
                      icon: _testing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check_rounded,
                              size: 16),
                      label: const Text('测试连接',
                          style: TextStyle(fontSize: 12.5)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: semantic.border),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        _testNote ?? _discoveryNote ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: (_testNote?.startsWith('连接正常') ?? false)
                                ? AppColors.success
                                : AppColors.danger),
                      ),
                    ),
                  ],
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
          _SectionHeader('记忆', semantic),
          Container(
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                leading: const Icon(Icons.psychology_outlined,
                    size: 20, color: AppColors.brandViolet),
                title: Text('记忆(Hermes)',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: semantic.textPrimary)),
                subtitle: Text('查看知识账本与遗忘规则',
                    style:
                        TextStyle(fontSize: 12, color: semantic.textTertiary)),
                trailing: Icon(Icons.chevron_right,
                    size: 18, color: semantic.textTertiary),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const MemoryPage()),
                ),
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
                  subtitle: Text('Shelly Hermes 2.0.0 (1)',
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


/// Humanizes gateway errors for the connection test; the full mapping
/// table lands in PHASE 28 (lib/core/error_messages.dart).
String _humanizeGatewayError(Object error) {
  if (error is GatewayException) {
    switch (error.statusCode) {
      case 401:
        return '密钥无效,请检查 API Key';
      case 404:
        return '接口地址不正确,通常以 /v1 结尾';
      case 429:
        return '模型限流中,请稍后重试';
      case 403:
        return '没有访问权限(403)';
    }
    return '连接失败(${error.statusCode ?? '未知错误'})';
  }
  return '连接失败:$error';
}
