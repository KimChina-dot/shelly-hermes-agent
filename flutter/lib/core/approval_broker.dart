import 'dart:async';

import 'models.dart';

/// A tool call awaiting a human decision.
class PendingApproval {
  PendingApproval(this.call) : decision = Completer<ApprovalDecision>();

  final ToolCall call;
  final Completer<ApprovalDecision> decision;
}

/// Platform-neutral [ApprovalGateway] that suspends the agent loop until a
/// human decision arrives via [resolve]. Ported from Kotlin `ApprovalBroker.kt`
/// using a [Completer] in place of CompletableFuture. A host (Flutter UI,
/// CLI prompt, test) renders `active` and resolves it.
///
/// On top of the ask-per-call flow the broker keeps a session-scoped
/// always-allow set (PHASE 48, the OpenAI HITL `always_approve` pattern):
/// a tool approved via [approveAlways] short-circuits [request] for the rest
/// of the session before any user ask happens. The set is in-memory only and
/// dies with the broker instance — it is never persisted, so the security
/// boundary stays per-session. Upstream auto-approval policies (e.g.
/// read-only tool allowlists at the AgentCore layer) are unaffected; this
/// allow set only removes asks that would otherwise reach the user.
class ApprovalBroker implements ApprovalGateway {
  PendingApproval? _pending;

  /// Tool names the user approved with "always allow" for this session.
  final Set<String> _allowSet = <String>{};

  /// Host callback invoked whenever a tool call needs a decision.
  void Function(PendingApproval approval)? launcher;

  @override
  Future<ApprovalDecision> request(ToolCall call) {
    if (_allowSet.contains(call.name)) {
      // Session-scoped always-allow: no pending approval, no launcher call.
      return Future<ApprovalDecision>.value(ApprovalDecision.approve);
    }
    final born = PendingApproval(call);
    _pending = born;
    launcher?.call(born);
    return born.decision.future;
  }

  /// Resolves the active pending request.
  ///
  /// Returns true when a pending request was resolved; false when there was
  /// nothing pending (e.g. the user opened the approval screen without an
  /// active agent request).
  bool resolve(ApprovalDecision decision) {
    final current = _pending;
    if (current == null) return false;
    _pending = null;
    current.decision.complete(decision);
    return true;
  }

  /// Records the tool NAME of [call] in the session-scoped allow set so
  /// future [request]s for that tool name are auto-approved without asking
  /// the user again. In-memory only: never written to any store.
  void approveAlways(ToolCall call) {
    _allowSet.add(call.name);
  }

  /// Unmodifiable snapshot of this session's always-allow tool names.
  Iterable<String> get allowSetView => List.unmodifiable(_allowSet);

  /// Drops every always-allow decision; the broker asks again for all tools.
  void clearAllowSet() => _allowSet.clear();

  PendingApproval? get active => _pending;
}

abstract interface class ApprovalGateway {
  Future<ApprovalDecision> request(ToolCall call);
}
