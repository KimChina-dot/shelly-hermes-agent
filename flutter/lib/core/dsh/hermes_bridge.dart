import '../hermes/knowledge.dart';
import '../hermes/knowledge_store.dart';

/// DSH↔Hermes linkage (PHASE 16): plugin lifecycle milestones land in the
/// knowledge ledger so the agent remembers which capabilities it has and
/// what they taught it. Best-effort by design — failures are swallowed.
class DshHermesBridge {
  DshHermesBridge({required this.store});

  final HermesKnowledgeStore store;

  Future<void> recordInstalled(String pluginId, String version) =>
      _record('$pluginId v$version 已安装:新增插件能力,可用时优先调用其工具');

  Future<void> recordEnabled(String pluginId) =>
      _record('$pluginId 已启用:其工具当前可被 agent 调用');

  Future<void> recordDisabled(String pluginId) =>
      _record('$pluginId 已停用:不要再尝试调用其工具');

  Future<void> recordFailed(String pluginId, String reason) =>
      _record('$pluginId 加载失败($reason):调用其工具前先检查宿主环境');

  Future<void> _record(String content) async {
    try {
      await store.append(KnowledgeEntry(
        id: 'dsh-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
        content: content,
        category: 'fact',
        source: 'reflection',
      ));
    } catch (_) {
      // Ledger write failures never block plugin lifecycle.
    }
  }
}
