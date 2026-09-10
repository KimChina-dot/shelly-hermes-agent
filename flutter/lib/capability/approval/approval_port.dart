import '../../core/models.dart';

export '../../core/approval_broker.dart' show PendingApproval;
export '../../core/models.dart' show ApprovalDecision, ToolCall;

/// PHASE 12 (v3.0 migration plan P9, risk R7): the capability seam for human
/// approval. Features consume approvals through this port instead of reaching
/// directly into `core/approval_broker.dart`, so the v3.0 audit finding
/// "features depend on the concrete core broker" is resolved at the type
/// level while the runtime wiring stays byte-identical.
///
/// The minimal face mirrors the broker's existing public approval flow:
///
///   * [request] suspends the caller until a human decision arrives (the
///     pending request is delivered to the host through the broker's
///     `launcher` callback);
///   * [resolve] delivers that decision back;
///   * [approveAlways] records a session-scoped always-allow for the tool
///     NAME (PHASE 48, the OpenAI HITL `always_approve` pattern);
///   * [isAlwaysAllowed] queries that always-allow state.
///
/// The shared vocabulary types are reused, never copied: [ToolCall] and
/// [ApprovalDecision] come from `core/models.dart`, and [PendingApproval]
/// (the handle a host renders and completes) is re-exported from the core
/// broker so feature imports can point at this port module alone.
///
/// `ApprovalBroker` remains the single production implementation
/// (`implements ApprovalPort`, zero behavior change); agent-core keeps its
/// narrower `ApprovalGateway` seam, which this port intentionally does not
/// depend on.
abstract interface class ApprovalPort {
  /// Suspends until a human decides on [call]. When [call]'s tool name is in
  /// the always-allow set the future completes immediately with
  /// [ApprovalDecision.approve] and no ask is surfaced.
  Future<ApprovalDecision> request(ToolCall call);

  /// Resolves the currently pending request, if any.
  ///
  /// Returns true when a pending request was resolved; false when nothing
  /// was pending.
  bool resolve(ApprovalDecision decision);

  /// Adds the tool NAME of [call] to the session-scoped always-allow set so
  /// future [request]s for that name are auto-approved without asking again.
  void approveAlways(ToolCall call);

  /// True when [toolName] is always-allowed this session (or was restored
  /// from the host's persistent store).
  bool isAlwaysAllowed(String toolName);
}
