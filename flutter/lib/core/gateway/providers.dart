/// How a provider exposes server-side web search. The app never scrapes the
/// web itself — it only flips the provider's own switch inside the request
/// body, so unsupported providers simply hide the toggle.
enum WebSearchSupport {
  /// No server-side search plugin.
  none,

  /// Provider plugin injected into `tools` (智谱 GLM `web_search` plugin).
  pluginTool,

  /// Provider routes by model-id suffix (OpenRouter `:online`).
  modelSuffix,
}

/// Provider presets (V2.0 PHASE 18): every OpenAI-compatible endpoint the
/// app knows out of the box. The gateway itself stays provider-agnostic —
/// a preset only fills in the base URL (and whether a key is expected).
class LlmProviderPreset {
  const LlmProviderPreset({
    required this.id,
    required this.label,
    required this.defaultBaseUrl,
    this.requiresApiKey = true,
    this.note = '',
    this.webSearch = WebSearchSupport.none,
  });

  final String id;
  final String label;
  final String defaultBaseUrl;
  final bool requiresApiKey;
  final String note;
  final WebSearchSupport webSearch;
}

const llmProviderPresets = <LlmProviderPreset>[
  LlmProviderPreset(
    id: 'openai',
    label: 'OpenAI',
    defaultBaseUrl: 'https://api.openai.com/v1',
  ),
  LlmProviderPreset(
    id: 'deepseek',
    label: 'DeepSeek',
    defaultBaseUrl: 'https://api.deepseek.com/v1',
  ),
  LlmProviderPreset(
    id: 'moonshot',
    label: 'Moonshot Kimi',
    defaultBaseUrl: 'https://api.moonshot.cn/v1',
  ),
  LlmProviderPreset(
    id: 'qwen',
    label: 'Qwen(兼容模式)',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  ),
  LlmProviderPreset(
    id: 'zhipu',
    label: '智谱 GLM',
    defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    webSearch: WebSearchSupport.pluginTool,
    note: '支持服务端联网搜索插件',
  ),
  LlmProviderPreset(
    id: 'openrouter',
    label: 'OpenRouter',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
    webSearch: WebSearchSupport.modelSuffix,
    note: '联网搜索经 :online 模型后缀开启',
  ),
  LlmProviderPreset(
    id: 'ollama',
    label: 'Ollama(本机)',
    defaultBaseUrl: 'http://localhost:11434/v1',
    requiresApiKey: false,
    note: '本机服务,无需 API Key',
  ),
  LlmProviderPreset(
    id: 'lmstudio',
    label: 'LM Studio(本机)',
    defaultBaseUrl: 'http://localhost:1234/v1',
    requiresApiKey: false,
    note: '本机服务,无需 API Key',
  ),
  LlmProviderPreset(
    id: 'custom',
    label: '自定义',
    defaultBaseUrl: '',
    note: '任何 OpenAI 兼容端点',
  ),
];

LlmProviderPreset? presetById(String id) =>
    llmProviderPresets.where((p) => p.id == id).firstOrNull;

/// Resolves web-search support from the configured base URL, so custom
/// endpoints pointed at a known provider still get the right injection.
WebSearchSupport webSearchSupportFor(String baseUrl) {
  final url = baseUrl.trim().toLowerCase();
  if (url.contains('bigmodel.cn')) return WebSearchSupport.pluginTool;
  if (url.contains('openrouter.ai')) return WebSearchSupport.modelSuffix;
  for (final preset in llmProviderPresets) {
    if (preset.defaultBaseUrl.isNotEmpty &&
        url == preset.defaultBaseUrl.toLowerCase()) {
      return preset.webSearch;
    }
  }
  return WebSearchSupport.none;
}
