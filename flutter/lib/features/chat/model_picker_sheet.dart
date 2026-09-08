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
  final _auxBaseUrl = TextEditingController();
  final _auxModel = TextEditingController();
  final _temperature = TextEditingController();
  final _topP = TextEditingController();
  final _maxTokens = TextEditingController();
  final _discovery = ModelDiscovery();
  bool _initialized = false;
  bool _discovering = false;
  bool _testing = false;
  bool _webSearch = false;
  bool _auxEnabled = false;
  bool _advancedOpen = false;
  Duration? _latency;
  String? _error;
  List<RemoteModel> _remoteModels = const [];

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _auxBaseUrl.dispose();
    _auxModel.dispose();
    _temperature.dispose();
    _topP.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  void _hydrate(ModelConfig config, SettingsStore? store) {
    _initialized = true;
    _baseUrl.text = config.baseUrl;
    _model.text = config.model;
    _webSearch = config.webSearchEnabled;
    if (config.temperature != null) {
      _temperature.text = _formatDouble(config.temperature!);
    }
    if (config.topP != null) _topP.text = _formatDouble(config.topP!);
    if (config.maxTokens != null) {
      _maxTokens.text = config.maxTokens.toString();
    }
    final aux = store?.loadAuxModelConfig();
    if (aux != null) {
      _auxBaseUrl.text = aux.baseUrl;
      _auxModel.text = aux.model;
      _auxEnabled = store!.auxEnabled;
    }
  }

  /// 1.0 prints as "1" so round-tripping a stored value doesn't grow a
  /// trailing decimal that implies non-integer precision.
  static String _formatDouble(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : value.toString();

  /// Parses an optional sampling field; blank or non-numeric input means
  /// "unset" and in-range values are clamped to [min] - [max].
  static double? _parseClampedDouble(String raw, double min, double max) {
    final value = double.tryParse(raw.trim());
    if (value == null) return null;
    return value.clamp(min, max).toDouble();
  }

  /// Max tokens stays an integer cap clamped to 1 - 32768; blank = unset.
  static int? _parseMaxTokens(String raw) {
    final value = int.tryParse(raw.trim());
    if (value == null) return null;
    return value.clamp(1, 32768);
  }

  bool get _hasAdvancedParams =>
      _temperature.text.trim().isNotEmpty ||
      _topP.text.trim().isNotEmpty ||
      _maxTokens.text.trim().isNotEmpty;

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
        temperature: _parseClampedDouble(_temperature.text, 0, 2),
        topP: _parseClampedDouble(_topP.text, 0, 1),
        maxTokens: _parseMaxTokens(_maxTokens.text),
      ),
    );
    // Auxiliary model for summaries/titles: no key field — those jobs reuse
    // the main model's API key at usage time.
    await store.saveAuxModelConfig(ModelConfig(
      baseUrl: _auxBaseUrl.text.trim(),
      model: _auxModel.text.trim(),
    ));
    await store.setAuxEnabled(_auxEnabled);
    ref.invalidate(settingsStoreProvider);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('已切换模型,下一轮对话生效')));
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final store = ref.watch(settingsStoreProvider).valueOrNull;
    final config = store?.modelConfig ?? const ModelConfig();
    // Hydrate only once the store is live so a slow load doesn't pin the
    // fields (main and aux) to empty values.
    if (!_initialized && store != null) _hydrate(config, store);
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
                            ? semantic.accent.withValues(alpha: 0.15)
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
                            ? semantic.success
                            : (_error == null
                                  ? semantic.textTertiary
                                  : semantic.danger),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  // Collapsed-by-default sampling params toggle; it rides in
                  // this row so the sheet keeps its height until expanded.
                  GestureDetector(
                    onTap: () =>
                        setState(() => _advancedOpen = !_advancedOpen),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: semantic.accent.withValues(
                          alpha:
                              _advancedOpen || _hasAdvancedParams ? 0.15 : 0.12,
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.tune,
                            size: 12,
                            color: semantic.textSecondary,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            '高级参数',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: semantic.textSecondary,
                            ),
                          ),
                          Icon(
                            _advancedOpen
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 12,
                            color: semantic.textSecondary,
                          ),
                        ],
                      ),
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
                      activeThumbColor: semantic.accent,
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
                    value: _auxEnabled,
                    onChanged: (value) => setState(() => _auxEnabled = value),
                    activeThumbColor: semantic.accent,
                    title: Text(
                      '辅助模型(摘要/标题)',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: semantic.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      '上下文压缩摘要、超长工具输出等轻量任务改用该模型;密钥沿用主模型',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: semantic.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
              if (_auxEnabled) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '辅助模型接口地址(Base URL)',
                  style: TextStyle(fontSize: 12, color: semantic.textTertiary),
                ),
                const SizedBox(height: AppSpacing.xs),
                TextField(
                  controller: _auxBaseUrl,
                  keyboardType: TextInputType.url,
                  style:
                      TextStyle(fontSize: 13.5, color: semantic.textPrimary),
                  decoration: const InputDecoration(
                    hintText: 'https://api.siliconflow.cn/v1',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '辅助模型名称',
                  style: TextStyle(fontSize: 12, color: semantic.textTertiary),
                ),
                const SizedBox(height: AppSpacing.xs),
                TextField(
                  controller: _auxModel,
                  style:
                      TextStyle(fontSize: 13.5, color: semantic.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '例如 Qwen/Qwen2.5-7B-Instruct',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              if (_advancedOpen) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '温度 temperature(0 - 2)',
                  style: TextStyle(fontSize: 12, color: semantic.textTertiary),
                ),
                const SizedBox(height: AppSpacing.xs),
                TextField(
                  controller: _temperature,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: TextStyle(fontSize: 13.5, color: semantic.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '留空使用默认,例如 0.7',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '核采样 top_p(0 - 1)',
                  style: TextStyle(fontSize: 12, color: semantic.textTertiary),
                ),
                const SizedBox(height: AppSpacing.xs),
                TextField(
                  controller: _topP,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: TextStyle(fontSize: 13.5, color: semantic.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '留空使用默认,例如 0.95',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '最大生成 tokens(1 - 32768)',
                  style: TextStyle(fontSize: 12, color: semantic.textTertiary),
                ),
                const SizedBox(height: AppSpacing.xs),
                TextField(
                  controller: _maxTokens,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 13.5, color: semantic.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '留空使用默认,例如 4096',
                  ),
                  onChanged: (_) => setState(() {}),
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
          color: semantic.accent.withValues(alpha: 0.12),
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
