// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../../core/agent_core.dart';
import '../../core/models.dart';

/// Budget-aware [ModelGateway] wrapper for Brain calls (PHASE 8).
///
/// Brain model calls are additional prefills against the agent's token
/// budget (see `Brain` in `planner.dart`), so every reply's input+output
/// tokens are recorded in [consumedTokens]; the integration layer hands
/// that total to [AgentContext.initialConsumedTokens], which seeds the
/// same counter the agent rounds charge. The wrapper only counts — it
/// never throttles, and a Brain call may never bypass the budget ledger.
class MeteredGateway implements ModelGateway {
  MeteredGateway({required ModelGateway inner}) : _inner = inner;

  final ModelGateway _inner;

  /// Input+output tokens of every [complete] call answered so far.
  int consumedTokens = 0;

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    final reply = await _inner.complete(messages);
    consumedTokens += reply.inputTokens + reply.outputTokens;
    return reply;
  }
}
