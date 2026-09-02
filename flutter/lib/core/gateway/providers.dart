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
  });

  final String id;
  final String label;
  final String defaultBaseUrl;
  final bool requiresApiKey;
  final String note;
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
    id: 'openrouter',
    label: 'OpenRouter',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
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
