// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../models.dart';
import '../runtime/agent_context.dart';
import 'forgetting.dart';
import 'knowledge.dart';
import 'knowledge_store.dart';
import 'reflection.dart';

/// Hermes (V2.0 PHASE 07): the memory half of the product, plugged into
/// the agent loop through [AgentMemoryAccess]. Recall injects relevant
/// ledger entries before the first round; remember appends a short entry
/// after completion, then runs reflection/forgetting upkeep. Every method
/// is safe to fail — AgentRuntime swallows memory errors by design.
class HermesMemory implements AgentMemoryAccess {
  HermesMemory({
    required this.store,
    this.autoCapture = true,
    this.maxAutoEntries = 60,
    this.minCaptureChars = 40,
    this.maxCaptureChars = 300,
    Reflector reflector = const Reflector(),
    ForgettingPolicy forgettingPolicy = const ForgettingPolicy(),
  })  : _reflector = reflector,
        _forgettingPolicy = forgettingPolicy;

  final HermesKnowledgeStore store;
  final Reflector _reflector;
  final ForgettingPolicy _forgettingPolicy;

  /// Whether finished replies are auto-recorded as candidate lessons.
  final bool autoCapture;
  final int maxAutoEntries;
  final int minCaptureChars;
  final int maxCaptureChars;

  @override
  Future<List<String>> recall(String task) => store.recall(task);

  @override
  Future<void> maybeRemember(String finalReply, AgentCheckpoint checkpoint) async {
    if (!autoCapture) return;
    final content = finalReply.trim();
    if (content.length < minCaptureChars) return;
    final entries = await store.loadAll();
    if (entries.length >= maxAutoEntries) return;
    final clipped = content.length > maxCaptureChars
        ? '${content.substring(0, maxCaptureChars)}…'
        : content;
    await store.append(KnowledgeEntry(
      id: nextEntryId(),
      content: clipped,
      category: 'lesson',
      source: 'agent',
      project: store.project,
    ));
    await _upkeep();
  }

  /// Reflection (PHASE 09) when the ledger outgrows its cap, then a
  /// forgetting pass (PHASE 10) to hold the token budget.
  Future<void> _upkeep() async {
    final entries = await store.loadAll();
    final size = entries.fold<int>(
      0,
      (sum, entry) => sum + entry.content.length + 96,
    );
    if (_reflector.shouldReflect(entries.length, size)) {
      await _reflector.reflect(store);
    }
    await store.applyForgetting(policy: _forgettingPolicy);
  }
}

int _idCounter = 0;

String nextEntryId() {
  _idCounter += 1;
  return 'k-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$_idCounter';
}
