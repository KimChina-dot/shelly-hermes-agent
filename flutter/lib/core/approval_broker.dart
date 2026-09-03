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
class ApprovalBroker implements ApprovalGateway {
  PendingApproval? _pending;

  /// Host callback invoked whenever a tool call needs a decision.
  void Function(PendingApproval approval)? launcher;

  @override
  Future<ApprovalDecision> request(ToolCall call) {
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

  PendingApproval? get active => _pending;
}

abstract interface class ApprovalGateway {
  Future<ApprovalDecision> request(ToolCall call);
}
