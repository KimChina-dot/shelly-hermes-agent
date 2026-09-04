import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_messages.dart';
import '../../core/gateway/model_discovery.dart';
import '../../core/gateway/providers.dart';
import '../../design/tokens.dart';
import '../../state/settings_store.dart';

/// Quick model switching from the chat page: pick a provider preset, fetch
/// the endpoint's model list, test the connection and apply. Writes the
/// global model config; the next task picks it up (config is re-read per
/// task). The API key is intentionally read-only here — secrets are edited
/// on the profile page only.
class ModelPickerSheet extends ConsumerStatefulWidget {
  const ModelPickerSheet({super.key});

  @override
  ConsumerState<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<ModelPickerSheet> {
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _discovery = ModelDiscovery();
  bool _initialized = false;
  bool _discovering = false;
  bool _testing = false;
  bool _webSearch = false;
  Duration? _latency;
  String? _error;
  List<RemoteModel> _remoteModels = const [];

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  void _hydrate(ModelConfig config) {
    _initialized = true;
    _baseUrl.text = config.baseUrl;
    _model.text = config.model;
    _webSearch = config.webSearchEnabled;
  }

  String get _apiKey =>
      ref.read(settingsStoreProvider).valueOrNull?.loadModelConfig().apiKey ??
      '';

  Future<void> _fetchModels() async {
    setState(() {
      _discovering = true;
      _error = null;
    });
    try {
      final models = await _discovery.listModels(
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey,
      );
      if (!mounted) return;
      setState(() {
        _discovering = false;
        _remoteModels = models;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _discovering = false;
        _error = '获取模型列表失败:$error';
      });
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _error = null;
      _latency = null;
    });
    try {
      final latency = await _discovery.testConnection(
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        apiKey: _apiKey,
      );
      if (!mounted) return;
      setState(() {
        _testing = false;
        _latency = latency;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = humanizeAgentError(error);
      });
    }
  }

  Future<void> _apply() async {
    final store = ref.read(settingsStoreProvider).valueOrNull;
    if (store == null) return;
    await store.saveModelConfig(
      ModelConfig(
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey,
        model: _model.text.trim(),
        webSearchEnabled: _webSearch,
      ),
    );
    ref.invalidate(settingsStoreProvider);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('已切换模型,下一轮对话生效')));
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final config = ref
        .watch(settingsStoreProvider)
        .maybeWhen(
          data: (store) => store.modelConfig,
          orElse: () => const ModelConfig(),
        );
    if (!_initialized) _hydrate(config);
    final hasKey = _apiKey.isNotEmpty;
    final canApply =
        _baseUrl.text.trim().isNotEmpty && _model.text.trim().isNotEmpty;
    final webSearchSupport = webSearchSupportFor(_baseUrl.text.trim());

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: semantic.card,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '切换模型',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: semantic.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '接口地址(Base URL)',
                style: TextStyle(fontSize: 12, color: semantic.textTertiary),
              ),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                style: TextStyle(fontSize: 13.5, color: semantic.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'https://api.deepseek.com/v1',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final preset in llmProviderPresets)
                    if (preset.defaultBaseUrl.isNotEmpty)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          preset.label,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        backgroundColor:
                            _baseUrl.text.trim() == preset.defaultBaseUrl
                            ? AppColors.brandBlue.withValues(alpha: 0.15)
                            : null,
                        onPressed: () {
                          _baseUrl.text = preset.defaultBaseUrl;
                          setState(() {});
                        },
                      ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '模型名称',
                style: TextStyle(fontSize: 12, color: semantic.textTertiary),
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _model,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: semantic.textPrimary,
                      ),
                      decoration: const InputDecoration(
                        hintText: '例如 deepseek-chat',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _busyIconAction(
                    label: '获取列表',
                    busy: _discovering,
                    enabled: _baseUrl.text.trim().isNotEmpty,
                    onTap: _fetchModels,
                  ),
                ],
              ),
              if (_remoteModels.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: AppSpacing.xs),
                  constraints: const BoxConstraints(maxHeight: 140),
                  decoration: BoxDecoration(
                    color: semantic.background,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _remoteModels.length,
                    itemBuilder: (context, index) => ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(
                        _remoteModels[index].id,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: semantic.textPrimary,
                        ),
                      ),
                      onTap: () {
                        _model.text = _remoteModels[index].id;
                        setState(() {});
                      },
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  _busyIconAction(
                    label: '测试连接',
                    busy: _testing,
                    enabled: canApply,
                    onTap: _testConnection,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _latency != null
                          ? '连接正常 · ${_latency!.inMilliseconds} ms'
                          : (_error ?? (hasKey ? '' : '密钥未配置,请到「我的」页填写')),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: _latency != null
                            ? Colors.green
                            : (_error == null
                                  ? semantic.textTertiary
                                  : AppColors.danger),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (webSearchSupport != WebSearchSupport.none) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  decoration: BoxDecoration(
                    color: semantic.background,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile(
                      dense: true,
                      value: _webSearch,
                      onChanged: (value) => setState(() => _webSearch = value),
                      activeThumbColor: AppColors.brandBlue,
                      title: Text(
                        '联网搜索',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: semantic.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        switch (webSearchSupport) {
                          WebSearchSupport.pluginTool =>
                            '由厂商服务端搜索插件提供,检索结果并入回复',
                          WebSearchSupport.modelSuffix =>
                            '请求经 :online 模型后缀路由到联网版本',
                          WebSearchSupport.none => '',
                        },
                        style: TextStyle(
                          fontSize: 11.5,
                          color: semantic.textTertiary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: canApply ? _apply : null,
                icon: const Icon(Icons.check_rounded, size: 17),
                label: const Text('使用此模型'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _busyIconAction({
    required String label,
    required bool busy,
    required bool enabled,
    required Future<void> Function() onTap,
  }) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return GestureDetector(
      onTap: busy || !enabled ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AppColors.brandBlue.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              )
            else
              Icon(Icons.sync_alt, size: 12, color: semantic.textSecondary),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: TextStyle(fontSize: 11.5, color: semantic.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
