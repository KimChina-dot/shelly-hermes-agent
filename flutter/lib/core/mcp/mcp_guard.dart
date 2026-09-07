import 'dart:convert';

import 'package:crypto/crypto.dart';

/// MCP supply-chain guard (PHASE 46).
///
/// ## Threat model
///
/// A server's tool descriptions are an invisible-to-the-user attack surface
/// (Invariant Labs: "tool poisoning" — a hostile instruction smuggled into a
/// tool description is executed by the agent but never shown to the human who
/// approves it). A **rug pull** is a server mutating its catalog (descriptions
/// or parameter schemas) *after* the user approved it, silently swapping
/// benign tools for hostile ones. The MCP spec's answer is pinning versions.
///
/// ## Mechanism
///
/// We pin the catalog itself: a SHA-256 fingerprint over the canonical JSON
/// of every tool (name + description + parameter schema, tools sorted by
/// name, map keys sorted recursively), recorded at approval time and
/// re-checked on every discovery. Anything that drifts is flagged
/// [GuardVerdict.changed] for re-approval and is never auto-trusted.
///
/// [McpGuard.tagUntrusted] additionally marks content pulled from untrusted
/// origins (search results, MCP tool output) before prompt injection.
enum GuardVerdict { unchanged, changed, firstSeen, removed }

/// Outcome of comparing two tool-catalog fingerprints.
class McpGuardReport {
  const McpGuardReport({
    required this.verdict,
    required this.summary,
    this.serverId = '',
    this.fingerprint = '',
  });

  /// Server the report belongs to ('' for bare [McpGuard.compare] results).
  final String serverId;

  final GuardVerdict verdict;

  /// The current catalog fingerprint this verdict was computed against
  /// ('' when the catalog is gone entirely).
  final String fingerprint;

  /// Human-readable one-liner for the UI / logs.
  final String summary;

  /// Changed or removed catalogs must be re-approved by the user before the
  /// controller may treat them as trusted again; firstSeen records a fresh
  /// catalog awaiting its first approval.
  bool get requiresReapproval =>
      verdict == GuardVerdict.changed || verdict == GuardVerdict.removed;

  McpGuardReport copyWith({String? serverId, String? fingerprint}) =>
      McpGuardReport(
        serverId: serverId ?? this.serverId,
        verdict: verdict,
        summary: summary,
        fingerprint: fingerprint ?? this.fingerprint,
      );
}

/// Tool-level delta between two raw catalogs (see [McpGuard.diffTools]).
class McpToolDiff {
  const McpToolDiff({
    this.added = const [],
    this.removed = const [],
    this.changedDescriptions = const [],
  });

  /// Names of tools that appeared in the current catalog.
  final List<String> added;

  /// Names of tools that vanished from the current catalog.
  final List<String> removed;

  /// `name: 描述变化` / `name: 参数 schema 变化` entries for tools that kept
  /// their name but drifted underneath it.
  final List<String> changedDescriptions;

  bool get isEmpty =>
      added.isEmpty && removed.isEmpty && changedDescriptions.isEmpty;

  String get summary {
    final parts = <String>[
      if (added.isNotEmpty) '新增工具: ${added.join(', ')}',
      if (removed.isNotEmpty) '移除工具: ${removed.join(', ')}',
      if (changedDescriptions.isNotEmpty)
        '描述/参数变更: ${changedDescriptions.join('; ')}',
    ];
    return parts.isEmpty ? '无变化' : parts.join(';');
  }
}

/// Pure-Dart fingerprinting / comparison helpers for the MCP supply-chain
/// guard. No Flutter dependencies; safe to use from any layer.
class McpGuard {
  const McpGuard._();

  /// SHA-256 over the canonical JSON of the tool catalog: tools sorted by
  /// name, map keys sorted recursively, only name + description + parameter
  /// schema contribute. The same content in any key or list order always
  /// produces the same hash.
  static String fingerprint(List<Map<String, dynamic>> tools) {
    final canonical = jsonEncode(_canonicalTools(tools));
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  /// Compares the previously approved fingerprint with the current one:
  /// `previous` null/empty → [GuardVerdict.firstSeen]; equal → unchanged;
  /// current empty or an empty-catalog hash → [GuardVerdict.removed];
  /// anything else → [GuardVerdict.changed] (suspected rug pull).
  static McpGuardReport compare(String? previous, String current) {
    if (previous == null || previous.isEmpty) {
      return McpGuardReport(
        verdict: GuardVerdict.firstSeen,
        summary: '首次记录工具目录指纹,等待用户批准',
        fingerprint: current,
      );
    }
    if (previous == current) {
      return McpGuardReport(
        verdict: GuardVerdict.unchanged,
        summary: '工具目录指纹一致',
        fingerprint: current,
      );
    }
    if (current.isEmpty || current == fingerprint(const [])) {
      return const McpGuardReport(
        verdict: GuardVerdict.removed,
        summary: '服务器不再提供任何工具,目录已被移除',
      );
    }
    return McpGuardReport(
      verdict: GuardVerdict.changed,
      summary: '工具目录指纹变化 — 疑似 rug pull,需用户重新批准',
      fingerprint: current,
    );
  }

  /// Tool-level delta between two raw catalogs — the human-readable "what
  /// changed" behind two differing fingerprints.
  static McpToolDiff diffTools(
    List<Map<String, dynamic>> previous,
    List<Map<String, dynamic>> current,
  ) {
    final before = {for (final tool in previous) _nameOf(tool): tool};
    final after = {for (final tool in current) _nameOf(tool): tool};
    final added =
        after.keys.where((name) => !before.containsKey(name)).toList()..sort();
    final removed =
        before.keys.where((name) => !after.containsKey(name)).toList()..sort();
    final changed = <String>[];
    for (final name in before.keys.where(after.containsKey)) {
      final oldTool = before[name]!;
      final newTool = after[name]!;
      final oldDesc = _descOf(oldTool);
      final newDesc = _descOf(newTool);
      if (oldDesc != newDesc) {
        changed.add('$name: "$oldDesc" → "$newDesc"');
      } else if (fingerprint([oldTool]) != fingerprint([newTool])) {
        changed.add('$name: 参数 schema 变化');
      }
    }
    changed.sort();
    return McpToolDiff(
      added: added,
      removed: removed,
      changedDescriptions: changed,
    );
  }

  /// Wraps untrusted content (search results, MCP tool output) with a
  /// deterministic marker line so downstream prompt assembly can never
  /// mistake it for user or system text.
  static String tagUntrusted(String source, String content) =>
      '[不可信来源: $source]\n$content';

  /// Canonical form: one entry per tool with a fixed key order
  /// (name → description → parameters), sorted by name; duplicate names fall
  /// back to content order so the hash stays deterministic even when a
  /// server serves the same name twice.
  static List<Map<String, dynamic>> _canonicalTools(
    List<Map<String, dynamic>> tools,
  ) {
    final canonical = [
      for (final tool in tools)
        <String, dynamic>{
          'name': _nameOf(tool),
          'description': _descOf(tool),
          'parameters': _canonicalValue(_paramsOf(tool)),
        },
    ]..sort((a, b) {
        final byName = (a['name'] as String).compareTo(b['name'] as String);
        if (byName != 0) return byName;
        return jsonEncode(a).compareTo(jsonEncode(b));
      });
    return canonical;
  }

  static String _nameOf(Map<String, dynamic> tool) =>
      tool['name'] as String? ?? '';

  static String _descOf(Map<String, dynamic> tool) =>
      tool['description'] as String? ?? '';

  /// Accepts both the MCP `inputSchema` and the OpenAI `parameters` spelling.
  static dynamic _paramsOf(Map<String, dynamic> tool) =>
      tool['inputSchema'] ?? tool['parameters'] ?? const <String, dynamic>{};

  /// Recursively sorts map keys (as strings) so JSON encoding is order-free;
  /// list order is preserved because parameter arrays are positional.
  static dynamic _canonicalValue(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return {
        for (final key in keys) key: _canonicalValue(value[key]),
      };
    }
    if (value is List) {
      return [for (final item in value) _canonicalValue(item)];
    }
    return value;
  }
}

/// Discovery-side ledger wiring the guard into `McpClient.listTools` — the
/// path `McpToolRegistry.connect` uses. The controller seeds it with the
/// approved fingerprints loaded from the settings store; every discovery
/// then records a per-server report here that the controller/UI can query.
///
/// The registry keeps working while a catalog is awaiting re-approval — the
/// flag below is a surface for the UI, not a gate: changed catalogs are
/// never auto-trusted, their tools still go through the high-risk approval
/// flow like every MCP tool.
class McpGuardLedger {
  McpGuardLedger._();

  static final Map<String, String> _approved = {};
  static final Map<String, McpGuardReport> _reports = {};

  /// Replaces the approved-fingerprint table (serverId → fingerprint),
  /// typically from `SettingsStore.loadMcpToolFingerprints()`.
  static void seedApproved(Map<String, String> fingerprints) {
    _approved
      ..clear()
      ..addAll(fingerprints);
  }

  static String? approvedFor(String serverId) => _approved[serverId];

  /// Verdict of the most recent discovery for [serverId], if any.
  static McpGuardReport? reportFor(String serverId) => _reports[serverId];

  /// All recorded reports (serverId → report), for bulk UI reads.
  static Map<String, McpGuardReport> get reports =>
      Map.unmodifiable(_reports);

  /// True when [serverId]'s latest catalog drifted from the approved
  /// fingerprint (changed or removed) and must be re-approved.
  static bool pendingReapproval(String serverId) =>
      _reports[serverId]?.requiresReapproval ?? false;

  /// True when any discovered server is awaiting re-approval.
  static bool get hasPendingReapproval =>
      _reports.values.any((report) => report.requiresReapproval);

  /// Records a fresh discovery: fingerprints [tools], compares against the
  /// approved fingerprint (ledger first, [configFingerprint] — the persisted
  /// `McpServerConfig.toolFingerprint` — second) and stores the report.
  static McpGuardReport record(
    String serverId,
    List<Map<String, dynamic>> tools, {
    String? configFingerprint,
  }) {
    final fingerprint = McpGuard.fingerprint(tools);
    final approved = _approved[serverId] ?? configFingerprint ?? '';
    final report = McpGuard.compare(
      approved.isEmpty ? null : approved,
      fingerprint,
    ).copyWith(serverId: serverId, fingerprint: fingerprint);
    _reports[serverId] = report;
    return report;
  }

  /// Clears every recorded report and approval (test isolation, wholesale
  /// server-list changes).
  static void reset() {
    _approved.clear();
    _reports.clear();
  }
}
