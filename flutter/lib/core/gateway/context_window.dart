/// Context-window presets per model family. Unknown models fall back to a
/// conservative window so compaction kicks in early rather than late.
int contextWindowForModel(String modelId) {
  final id = modelId.toLowerCase();
  if (id.contains('claude')) return 200000;
  if (id.contains('gemini-1.5-pro') || id.contains('gemini-2')) return 1000000;
  if (id.contains('gpt-4o') ||
      id.contains('gpt-4.1') ||
      id.contains('gpt-5') ||
      id.contains('o1') ||
      id.contains('o3') ||
      id.contains('o4')) {
    return 128000;
  }
  if (id.contains('glm-4')) return 128000;
  if (id.contains('deepseek')) return 65536;
  if (id.contains('qwen')) return 131072;
  if (id.contains('moonshot') || id.contains('kimi')) return 131072;
  if (id.contains('doubao') || id.contains('ERNIE'.toLowerCase())) return 128000;
  return 32768;
}
