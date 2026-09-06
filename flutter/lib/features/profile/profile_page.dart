import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart' show themeModeProvider;
import '../../core/agent_profile.dart';
import '../../core/crash/crash_log_store.dart';
import '../../core/error_messages.dart';
import '../../core/gateway/model_discovery.dart';
import '../../core/gateway/providers.dart';
import '../../design/components/buttons.dart';
import '../../design/tokens.dart';
import '../../features/memory/memory_page.dart';
import '../../features/shell/home_shell.dart' show tabIndexProvider;
import 'profile_editor_sheet.dart';
import '../../platform/platform_workspace.dart';
import '../../state/chat_session.dart'
    show workspaceAuthorizedProvider, workspaceProvider;

import '../../state/lan_companion.dart';
import '../../state/settings_store.dart';
import '../../state/update_check.dart';
import '../../state/usage_stats.dart';

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
  bool _checkingUpdate = false;
  UpdateCheckResult? _updateResult;

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
        _testNote = humanizeAgentError(error);
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

  /// Queries the GitHub release feed (PHASE 42). The button always forces a
  /// fresh network check; a newer release renders the inline card, anything
  /// else reports 已是最新. The service itself never throws.
  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
      _updateResult = null;
    });
    try {
      final service = await ref.read(updateCheckProvider.future);
      final result = await service.checkForUpdate(force: true);
      if (!mounted) return;
      if (result == null || !result.isNewer) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已是最新')),
        );
      } else {
        setState(() => _updateResult = result);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检查更新失败,请稍后重试')),
      );
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  /// Opens the release page in the external browser.
  Future<void> _openDownloadPage(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http'))) {
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开下载页')),
      );
    }
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
    // Usage stats are written by the chat session outside this page's
    // build cycle; re-read them every time this tab becomes active.
    ref.listen<int>(tabIndexProvider, (previous, next) {
      if (next == 4) {
        ref.invalidate(usageStatsProvider);
        ref.invalidate(crashLogProvider);
      }
    });
    if (!_initialized) {
      _hydrate(config);
      if (isAndroidHost) _checkWorkspace();
    }

    final themeMode = ref.watch(themeModeProvider);
    final update = ref.watch(updateCheckProvider).valueOrNull;
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
                            IconButton(
                              tooltip: profile.isPreset ? '复制并编辑' : '编辑档案',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => showProfileEditor(
                                  context, ref,
                                  profile: profile),
                              icon: Icon(
                                profile.isPreset
                                    ? Icons.copy_rounded
                                    : Icons.edit_outlined,
                                size: 17,
                                color: semantic.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                TextButton.icon(
                  onPressed: () => showProfileEditor(context, ref),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建档案',
                      style: TextStyle(fontSize: 12.5)),
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
          _SectionHeader('语音', semantic),
          Container(
            decoration: BoxDecoration(
              color: semantic.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: semantic.border),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.xs),
              leading: const Icon(Icons.volume_up_outlined,
                  size: 20, color: AppColors.brandViolet),
              title: Text('朗读助手回复',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: semantic.textPrimary)),
              subtitle: Text('开启后助手消息下方出现朗读按钮',
                  style:
                      TextStyle(fontSize: 12, color: semantic.textTertiary)),
              trailing: Switch(
                value: store?.ttsEnabled ?? false,
                onChanged: store == null
                    ? null
                    : (value) async {
                        await store.setTtsEnabled(value);
                        ref.invalidate(settingsStoreProvider);
                      },
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _SectionHeader('局域网伴侣', semantic),
          const _LanCompanionCard(),
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
          _SectionHeader('用量统计', semantic),
          _UsageCard(usage: ref.watch(usageStatsProvider).valueOrNull, semantic: semantic),
          const SizedBox(height: AppSpacing.xl),
          _SectionHeader('诊断', semantic),
          const _DiagnosticsCard(),
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
                  subtitle: Text(_versionLabel(update),
                      style: TextStyle(
                          fontSize: 12, color: semantic.textTertiary)),
                  trailing: _checkingUpdate
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(
                          onPressed: _checkForUpdate,
                          child: const Text('检查更新',
                              style: TextStyle(fontSize: 12.5)),
                        ),
                ),
              ],
            ),
          ),
          if (_updateResult != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _UpdateCard(
              result: _updateResult!,
              semantic: semantic,
              onOpenDownload: () =>
                  _openDownloadPage(_updateResult!.downloadUrl),
            ),
          ],
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

/// Local token usage overview (PHASE 40): totals over the retained 30-day
/// window plus a per-model breakdown with the prompt/completion split.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.usage, required this.semantic});

  final UsageStatsStore? usage;
  final AppSemanticColors semantic;

  @override
  Widget build(BuildContext context) {
    final totals = usage?.totals() ?? const UsageTotals();
    final byModel = usage?.totalsByModel() ?? const <String, UsageTotals>{};
    final modelIds = byModel.keys.toList()..sort();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: totals.rounds == 0
          ? Text('暂无用量记录,对话后自动统计(保留 30 天)',
              style: TextStyle(fontSize: 12, color: semantic.textTertiary))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.data_usage_outlined,
                        size: 18, color: AppColors.brandBlue),
                    const SizedBox(width: AppSpacing.sm),
                    Text('${totals.totalTokens} tokens',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: semantic.textPrimary)),
                    const Spacer(),
                    Text(
                        '输入 ${totals.promptTokens} · 输出 ${totals.completionTokens} · ${totals.rounds} 轮',
                        style: TextStyle(
                            fontSize: 11.5, color: semantic.textTertiary)),
                  ],
                ),
                if (modelIds.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  for (final modelId in modelIds)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Row(
                        children: [
                          const Icon(Icons.memory_outlined,
                              size: 15, color: AppColors.brandViolet),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(modelId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: semantic.textSecondary)),
                          ),
                          Text(
                              '${byModel[modelId]!.totalTokens} tokens · '
                              '输入 ${byModel[modelId]!.promptTokens} · '
                              '输出 ${byModel[modelId]!.completionTokens}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: semantic.textTertiary)),
                        ],
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}

/// Local crash diagnostics (PHASE 41): a count summary with a clear action,
/// then one expandable tile per recorded crash (time, source layer, error
/// text and a truncated stack), plus copy-to-clipboard for the details.
class _DiagnosticsCard extends ConsumerStatefulWidget {
  const _DiagnosticsCard();

  @override
  ConsumerState<_DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends ConsumerState<_DiagnosticsCard> {
  Future<void> _copyDetail(CrashEntry entry) async {
    final buffer = StringBuffer()
      ..writeln('时间: ${_formatCrashTime(entry.at)}')
      ..writeln('来源: ${entry.context}')
      ..writeln('错误: ${entry.error}')
      ..write('堆栈:\n${entry.stack}');
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制崩溃详情')),
    );
  }

  Future<void> _confirmClear(CrashLogStore store, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空崩溃记录'),
        content: Text('将删除本地保存的全部 $count 条记录,此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.clear();
    ref.invalidate(crashLogProvider);
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final store = ref.watch(crashLogProvider).valueOrNull;
    final entries = store?.loadEntries() ?? const <CrashEntry>[];
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: entries.isEmpty
          ? Text('暂无崩溃记录,系统运行正常',
              style: TextStyle(fontSize: 12, color: semantic.textTertiary))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bug_report_outlined,
                        size: 18, color: AppColors.brandViolet),
                    const SizedBox(width: AppSpacing.sm),
                    Text('${entries.length} 条崩溃记录',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: semantic.textPrimary)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _confirmClear(store!, entries.length),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                      label:
                          const Text('清空', style: TextStyle(fontSize: 12.5)),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: AppColors.danger,
                      ),
                    ),
                  ],
                ),
                for (final entry in entries)
                  Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: Colors.transparent),
                    child: Material(
                      type: MaterialType.transparency,
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding:
                            const EdgeInsets.only(bottom: AppSpacing.sm),
                        collapsedIconColor: semantic.textTertiary,
                        iconColor: semantic.textTertiary,
                        title: Text(
                            '${_formatCrashTime(entry.at)} · '
                            '${entry.context == 'platform' ? '平台' : '框架'}',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: semantic.textSecondary)),
                        subtitle: Text(entry.error,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: semantic.textTertiary)),
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            decoration: BoxDecoration(
                              color: semantic.background,
                              borderRadius:
                                  BorderRadius.circular(AppRadius.md),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    '时间 ${_formatCrashTime(entry.at)} · '
                                    '来源 ${entry.context}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: semantic.textTertiary)),
                                const SizedBox(height: AppSpacing.xs),
                                Text(entry.error,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: semantic.textPrimary)),
                                const SizedBox(height: AppSpacing.xs),
                                Text(_truncateCrashStack(entry.stack),
                                    maxLines: 10,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        fontFamily: 'monospace',
                                        height: 1.3,
                                        color: semantic.textTertiary)),
                              ],
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () => _copyDetail(entry),
                              icon: const Icon(Icons.copy_rounded, size: 14),
                              label: const Text('复制详情',
                                  style: TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                foregroundColor: AppColors.brandBlue,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

String _formatCrashTime(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}-'
    '${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')} '
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}:'
    '${at.second.toString().padLeft(2, '0')}';

/// Version line for the 关于 row; falls back gracefully while the package
/// info provider is still loading (or on hosts without the plugin).
String _versionLabel(UpdateCheckService? update) {
  final version = update?.currentVersion ?? '';
  if (version.isEmpty) return 'Shelly Hermes';
  final build = update?.currentBuild ?? '';
  return build.isEmpty ? 'Shelly Hermes $version' : 'Shelly Hermes $version ($build)';
}

/// Keeps the tile body compact even when a full 2000-char stack was stored.
String _truncateCrashStack(String stack, [int max = 800]) =>
    stack.length <= max ? stack : '${stack.substring(0, max)}…';

/// New-release card (PHASE 42): version headline, a release-notes excerpt
/// and the jump to the GitHub download page in the external browser.
class _UpdateCard extends StatelessWidget {
  const _UpdateCard({
    required this.result,
    required this.semantic,
    required this.onOpenDownload,
  });

  final UpdateCheckResult result;
  final AppSemanticColors semantic;
  final VoidCallback onOpenDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.brandBlue),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt_rounded,
                  size: 18, color: AppColors.brandBlue),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('发现新版本 v${result.latestVersion}',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: semantic.textPrimary)),
              ),
            ],
          ),
          if (result.notes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(result.notes,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: semantic.textSecondary)),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onOpenDownload,
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text('打开下载页', style: TextStyle(fontSize: 12.5)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: AppColors.brandBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// LAN companion pairing card (PHASE 42): the read-only server toggle plus
/// the LAN addresses, port and pairing token a desktop client needs. The
/// companion server lifecycle lives in the provider; this card only renders
/// its state.
class _LanCompanionCard extends ConsumerStatefulWidget {
  const _LanCompanionCard();

  @override
  ConsumerState<_LanCompanionCard> createState() => _LanCompanionCardState();
}

class _LanCompanionCardState extends ConsumerState<_LanCompanionCard> {
  List<String> _addresses = const [];

  @override
  void initState() {
    super.initState();
    _refreshAddresses();
  }

  Future<void> _refreshAddresses() async {
    final addresses = await lanIPv4Addresses();
    if (!mounted) return;
    setState(() => _addresses = addresses);
  }

  Future<void> _toggle(bool value) async {
    await ref.read(lanCompanionProvider.notifier).setEnabled(value);
    if (value) await _refreshAddresses();
  }

  Future<void> _copyToken(String token) async {
    await Clipboard.setData(ClipboardData(text: token));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制配对令牌')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final state = ref.watch(lanCompanionProvider);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: semantic.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.lan_outlined,
                  size: 20, color: AppColors.brandBlue),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('局域网只读访问',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: semantic.textPrimary)),
              ),
              Switch(value: state.enabled, onChanged: _toggle),
            ],
          ),
          Text(
            '开启后,同一局域网内的桌面客户端可凭配对令牌只读获取状态与对话记录',
            style: TextStyle(fontSize: 12, color: semantic.textTertiary),
          ),
          if (state.enabled) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(
                  state.running
                      ? Icons.check_circle
                      : state.error == null
                          ? Icons.autorenew
                          : Icons.error_outline,
                  size: 15,
                  color: state.running
                      ? AppColors.success
                      : state.error == null
                          ? semantic.textTertiary
                          : AppColors.danger,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    state.error ??
                        (state.running
                            ? '运行中 · 端口 ${state.port}'
                            : '启动中…'),
                    style: TextStyle(
                        fontSize: 12,
                        color: state.error != null
                            ? AppColors.danger
                            : state.running
                                ? AppColors.success
                                : semantic.textTertiary),
                  ),
                ),
                if (!state.running && state.error == null)
                  const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (state.running) ...[
              const SizedBox(height: AppSpacing.sm),
              if (_addresses.isEmpty)
                Text('未发现局域网 IPv4 地址,请检查网络连接',
                    style: TextStyle(
                        fontSize: 12, color: semantic.textTertiary))
              else
                for (final address in _addresses)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text('http://$address:${state.port}',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontFamily: 'monospace',
                            color: semantic.textSecondary)),
                  ),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: semantic.background,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('配对令牌',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: semantic.textTertiary)),
                          const SizedBox(height: 2),
                          Text(state.token,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  letterSpacing: 1.5,
                                  color: semantic.textPrimary)),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: state.token.isEmpty
                          ? null
                          : () => _copyToken(state.token),
                      icon: const Icon(Icons.copy_rounded, size: 14),
                      label: const Text('复制令牌',
                          style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: AppColors.brandBlue,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '桌面端在请求头携带 X-Shelly-Token(或 ?token= 参数),'
                '即可只读访问 /status、/conversations、/conversation/{id}。',
                style: TextStyle(
                    fontSize: 11.5, height: 1.4, color: semantic.textTertiary),
              ),
            ],
          ],
        ],
      ),
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
