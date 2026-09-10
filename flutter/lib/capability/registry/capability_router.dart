import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'capability.dart';
import 'capability_registry.dart';

/// Scored capability: the router's relevance-adjusted ranking entry.
@immutable
class ScoredCapability {
  const ScoredCapability({required this.capability, required this.score});

  final Capability capability;
  final double score;
}

/// Capability router (v3.0 §22): ranks capabilities for a task hint using
/// the master-plan formula — relevance (keyword overlap against name,
/// description and tool names) − risk penalty + trust bonus. Pure functions:
/// no I/O, no state.
class CapabilityRouter {
  const CapabilityRouter();

  /// Risk penalty weight: a high-risk capability needs proportionally more
  /// relevance to outrank a safer one.
  static const double riskPenaltyWeight = 0.3;

  /// Trust bonus weight: historical success rate adds up to 0.2.
  static const double trustBonusWeight = 0.2;

  /// Ranks [registry] capabilities for [taskHint], best first. Ties keep
  /// registration order (stable sort).
  List<ScoredCapability> rank(
    CapabilityRegistry registry, {
    required String taskHint,
  }) {
    final scored = [
      for (final c in registry.all())
        ScoredCapability(capability: c, score: score(c, taskHint: taskHint)),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return List.unmodifiable(scored);
  }

  /// relevance − riskPenaltyWeight × risk + trustBonusWeight × successRate,
  /// clamped to [0, 1].
  double score(Capability capability, {required String taskHint}) {
    final relevance = _relevance(capability, taskHint);
    final trust = capability.trust;
    final trustBonus =
        trust == null || trust.uses == 0 ? 0.0 : trust.successRate;
    final value =
        relevance - riskPenaltyWeight * capability.riskWeight +
            trustBonusWeight * trustBonus;
    return value.clamp(0.0, 1.0);
  }

  /// Keyword overlap between the task hint and (name + description + tool
  /// names), normalized to 0-1 by the number of hint tokens.
  double _relevance(Capability capability, String taskHint) {
    final hintTokens = _tokens(taskHint);
    if (hintTokens.isEmpty) return 0;
    final haystack = _tokens([
      capability.name,
      capability.description,
      for (final tool in capability.tools) tool.name,
    ].join(' '));
    var hits = 0;
    for (final token in hintTokens) {
      if (haystack.contains(token)) hits++;
    }
    return hits / hintTokens.length;
  }

  /// Lower-cased tokens; splits on whitespace and strips punctuation.
  static Set<String> _tokens(String text) {
    return LinkedHashSet.from(
      text
          .toLowerCase()
          .split(RegExp(r'[\s,，。.:;；/\\()()【】\[\]+\-_]+'))
          .where((t) => t.isNotEmpty),
    );
  }
}
