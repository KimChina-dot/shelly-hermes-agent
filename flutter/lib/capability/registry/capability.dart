import 'package:flutter/foundation.dart';

import '../../core/tools/registry.dart' show ToolSpec;

/// PHASE 4 (v3.0 §20): the unit of the unified capability layer. The agent
/// sees Capabilities — never raw MCP servers, DSh plugins or bare tool
/// registries. One [Capability] wraps one AgentToolRegistry's tool set.
///
/// Risk levels follow the master plan §38:
/// L0 read · L1 local write · L2 execute · L3 destructive · L4 external.
enum CapabilityCategory {
  filesystem,
  terminal,
  search,
  memory,
  knowledge,
  mcp,
  dsh,
  platform,
}

/// L0-L4 per master plan §38.
enum CapabilityRiskLevel {
  l0Read,
  l1LocalWrite,
  l2Execute,
  l3Destructive,
  l4ExternalSensitive,
}

/// Historical trust data for this capability, fed by TrustStore.
@immutable
class TrustScore {
  const TrustScore({
    this.uses = 0,
    this.successes = 0,
    this.failures = 0,
  });

  final int uses;
  final int successes;
  final int failures;

  /// successes / uses; 0 when never used.
  double get successRate => uses == 0 ? 0 : successes / uses;

  TrustScore copyWith({int? uses, int? successes, int? failures}) =>
      TrustScore(
        uses: uses ?? this.uses,
        successes: successes ?? this.successes,
        failures: failures ?? this.failures,
      );

  @override
  bool operator ==(Object other) =>
      other is TrustScore &&
      other.uses == uses &&
      other.successes == successes &&
      other.failures == failures;

  @override
  int get hashCode => Object.hash(uses, successes, failures);
}

/// A registered capability: id, metadata, risk level, and the tool specs it
/// exposes to the agent.
@immutable
class Capability {
  const Capability({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.riskLevel,
    this.tools = const [],
    this.trust,
  });

  final String id;
  final String name;
  final String description;
  final CapabilityCategory category;
  final CapabilityRiskLevel riskLevel;
  final List<ToolSpec> tools;
  final TrustScore? trust;

  /// Risk as a 0-1 penalty weight for the router (L0=0 … L4=1).
  double get riskWeight => switch (riskLevel) {
        CapabilityRiskLevel.l0Read => 0.0,
        CapabilityRiskLevel.l1LocalWrite => 0.25,
        CapabilityRiskLevel.l2Execute => 0.5,
        CapabilityRiskLevel.l3Destructive => 0.75,
        CapabilityRiskLevel.l4ExternalSensitive => 1.0,
      };

  Capability copyWith({TrustScore? trust}) => Capability(
        id: id,
        name: name,
        description: description,
        category: category,
        riskLevel: riskLevel,
        tools: tools,
        trust: trust ?? this.trust,
      );

  @override
  bool operator ==(Object other) =>
      other is Capability &&
      other.id == id &&
      other.name == name &&
      other.category == category &&
      other.riskLevel == riskLevel;

  @override
  int get hashCode => Object.hash(id, name, category, riskLevel);
}
