import 'package:flutter/foundation.dart';

/// PHASE 4 (v3.0 §26): historical trust data for one capability, fed by
/// TrustStore.record and consumed by the capability router's trust bonus.
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
