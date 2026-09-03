import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/gateway/model_discovery.dart';
import '../../core/gateway/openai_gateway.dart' show GatewayException;
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
        _error = _humanizeGatewayError(error);
      });
    }
  }

  Future<void> _apply() async {
    final store = ref.read(settingsStoreProvider).valueOrNull;
    if (store == null) return;
    await store.saveModelConfig(ModelConfig(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey,
      model: _model.text.trim(),
    ));
    ref.invalidate(settingsStoreProvider);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已切换模型,下一轮对话生效')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final config = ref.watch(settingsStoreProvider).maybeWhen(
          data: (store) => store.modelConfig,
          orElse: () => const ModelConfig(),
        );
    if (!_initialized) _hydrate(config);
    final hasKey = _apiKey.isNotEmpty;
    final canApply =
        _baseUrl.text.trim().isNotEmpty && _model.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
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
              Text('切换模型',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: semantic.textPrimary)),
              const SizedBox(height: AppSpacing.md),
              Text('接口地址(Base URL)',
                  style: TextStyle(
                      fontSize: 12, color: semantic.textTertiary)),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                style: TextStyle(
                    fontSize: 13.5, color: semantic.textPrimary),
                decoration: const InputDecoration(
                    hintText: 'https://api.deepseek.com/v1'),
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
                        label: Text(preset.label,
                            style: const TextStyle(fontSize: 11.5)),
                        backgroundColor: _baseUrl.text.trim() ==
                                preset.defaultBaseUrl
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
              Text('模型名称',
                  style: TextStyle(
                      fontSize: 12, color: semantic.textTertiary)),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _model,
                      style: TextStyle(
                          fontSize: 13.5, color: semantic.textPrimary),
                      decoration:
                          const InputDecoration(hintText: '例如 deepseek-chat'),
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
                      title: Text(_remoteModels[index].id,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: semantic.textPrimary)),
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
                                  : AppColors.danger)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
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
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
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
            Text(label,
                style: TextStyle(
                    fontSize: 11.5, color: semantic.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// Humanizes the gateway/discovery errors the picker can surface; the full
/// mapping table lands in PHASE 28 (lib/core/error_messages.dart).
String _humanizeGatewayError(Object error) {
  if (error is GatewayException) {
    switch (error.statusCode) {
      case 401:
        return '密钥无效,请到「我的」页检查 API Key';
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
