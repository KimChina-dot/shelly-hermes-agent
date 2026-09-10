import 'dart:async';

// ToolCall/ApprovalDecision arrive via this import too: the port module
// re-exports the shared vocabulary (PHASE 12).
import '../capability/approval/approval_port.dart';

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
///
/// PHASE 50 adds OPTIONAL persistence composition on top of the unchanged
/// PHASE 48 semantics. The broker itself still writes nothing to disk; a host
/// that wants cross-session memory injects:
///
///   * `initialPersistentAllow` — tool names restored from the host's store
///     at construction time. They behave exactly like session approvals for
///     [isAlwaysAllowed] / [request], but [clearAllowSet] does NOT remove
///     them (use [clearPersistentAllow] instead).
///   * `onAllowAlwaysPersist` — invoked by [approveAlways] in addition to the
///     in-memory session insert, so the host can write the tool name to its
///     persistent store (the WIRER decides the storage policy and key space).
///
/// With neither hook provided the broker is byte-identical to PHASE 48.
/// Revocation of persisted entries lives with the host store (app-data clear
/// or a future settings entry); this class only exposes [persistentAllowView]
/// and [clearPersistentAllow] for the in-memory mirror.
///
/// PHASE 12 (R7): the broker also satisfies the capability-level
/// [ApprovalPort] seam, so features can depend on the port type instead of
/// this concrete class. Implementing the port is purely additive — every
/// public behavior above is byte-identical.
class ApprovalBroker implements ApprovalGateway, ApprovalPort {
  ApprovalBroker({
    Set<String>? initialPersistentAllow,
    this.onAllowAlwaysPersist,
  }) : _persistentAllow = initialPersistentAllow == null
            ? <String>{}
            : Set<String>.of(initialPersistentAllow);

  PendingApproval? _pending;

  /// Tool names the user approved with "always allow" for this session.
  final Set<String> _allowSet = <String>{};

  /// In-memory mirror of the host-persisted always-allow tool names.
  final Set<String> _persistentAllow;

  /// Host hook invoked by [approveAlways] so the tool name can be written to
  /// a persistent store. Null (the default) means "never persist".
  void Function(String toolName)? onAllowAlwaysPersist;

  /// Host callback invoked whenever a tool call needs a decision.
  void Function(PendingApproval approval)? launcher;

  /// True when [toolName] is allowed for the rest of the session OR was
  /// restored from the host's persistent store.
  @override
  bool isAlwaysAllowed(String toolName) =>
      _allowSet.contains(toolName) || _persistentAllow.contains(toolName);

  @override
  Future<ApprovalDecision> request(ToolCall call) {
    if (isAlwaysAllowed(call.name)) {
      // Session-scoped (or persisted) always-allow: no pending approval, no
      // launcher call.
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
  @override
  bool resolve(ApprovalDecision decision) {
    final current = _pending;
    if (current == null) return false;
    _pending = null;
    current.decision.complete(decision);
    return true;
  }

  /// Records the tool NAME of [call] in the session-scoped allow set so
  /// future [request]s for that tool name are auto-approved without asking
  /// the user again. In-memory only: never written to any store. When the
  /// host provided [onAllowAlwaysPersist], the hook is additionally invoked
  /// with the tool name so the host can persist it across sessions.
  @override
  void approveAlways(ToolCall call) {
    _allowSet.add(call.name);
    onAllowAlwaysPersist?.call(call.name);
  }

  /// Unmodifiable snapshot of this session's always-allow tool names.
  Iterable<String> get allowSetView => List.unmodifiable(_allowSet);

  /// Unmodifiable snapshot of the persisted always-allow tool names this
  /// broker was constructed with (minus anything revoked via
  /// [clearPersistentAllow]). The backing store itself belongs to the host.
  Iterable<String> get persistentAllowView => List.unmodifiable(_persistentAllow);

  /// Drops every always-allow decision; the broker asks again for all tools.
  /// Clears ONLY the session set — persisted entries restored via
  /// [initialPersistentAllow] keep suppressing asks until revoked through
  /// [clearPersistentAllow] (which updates only this broker's in-memory
  /// mirror; the host store must be updated by the host).
  void clearAllowSet() => _allowSet.clear();

  /// Removes [toolName] from the broker's in-memory mirror of the persisted
  /// allow set so it asks again this session. No effect on the session set
  /// or on whatever the host persists.
  void clearPersistentAllow(String toolName) =>
      _persistentAllow.remove(toolName);

  PendingApproval? get active => _pending;
}

abstract interface class ApprovalGateway {
  Future<ApprovalDecision> request(ToolCall call);
}
