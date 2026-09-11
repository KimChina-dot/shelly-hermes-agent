import 'dart:async';

import 'migration_manager.dart';
import 'migration_prefs.dart';

/// One durable evidence line for the migration ledger. Wired to
/// [CrashLogStore.record] in production (the same sink the audit plan
/// routes validate-stage key issues to); tests inject a collector.
typedef MigrationEvidenceSink = Future<void> Function(
  String context,
  Object message,
);

/// PHASE 18 (plan P8) cutover seam: runs the five-stage migration exactly
/// once per install at app boot, between crash logging and `runApp`.
///
/// Contract (V3_MIGRATION_PLAN.md §2 P8):
/// - **never blocks, never throws**: any failure — including the timeout —
///   is folded into one evidence line and swallowed. The migration is
///   idempotent (terminal-state guard skips completed/rolled-back installs;
///   a run killed mid-way re-anchors on the surviving backup next boot), so
///   a skipped timeout costs nothing but a later re-run.
/// - **old keys are the rollback anchor**: the manager never deletes them,
///   and the app's readers still point at the old paths, so even a
///   rolled-back migration leaves behavior byte-identical.
/// - **evidence**: the outcome line lands in the crash log so the upgrade
///   matrix drill and field debugging share one artifact.
Future<void> runStartupMigration({
  required MigrationPrefs prefs,
  MigrationEvidenceSink? evidence,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final result = await MigrationManager(
      prefs: prefs,
      logger: evidence == null
          ? null
          : (message) => evidence('migration.log', message),
    ).run().timeout(timeout);
    await _record(
      evidence,
      'migration.result',
      _summary(result, stopwatch.elapsedMilliseconds),
    );
  } on TimeoutException {
    await _record(
      evidence,
      'migration.timeout',
      'migration exceeded ${timeout.inSeconds}s at boot; '
      'boot continues, the idempotent run repeats next launch '
      '(${stopwatch.elapsedMilliseconds}ms)',
    );
  } catch (error) {
    // MigrationManager.run never throws by contract; this guards the
    // unexpected (constructor, timeout wiring) so startup cannot die here.
    await _record(
      evidence,
      'migration.error',
      'unexpected failure: $error (${stopwatch.elapsedMilliseconds}ms)',
    );
  }
}

String _summary(MigrationResult result, int elapsedMs) {
  final state = result.skipped
      ? 'skipped(prior terminal state)'
      : result.rolledBack
          ? MigrationManager.stateRolledBack
          : result.success
              ? MigrationManager.stateCompleted
              : MigrationManager.stateFailed;
  return 'state=$state'
      ' backedUp=${result.backedUpKeys.length}'
      ' migrated=${result.migratedKeys.length}'
      ' invalid=${result.invalidKeys.length}'
      ' unknown=${result.unknownKeys.length}'
      ' reusedBackup=${result.reusedBackup}'
      ' rolledBack=${result.rolledBack}'
      ' error=${result.errorMessage ?? '-'}'
      ' elapsedMs=$elapsedMs';
}

Future<void> _record(
  MigrationEvidenceSink? evidence,
  String context,
  Object message,
) async {
  if (evidence == null) return;
  try {
    await evidence(context, message);
  } catch (_) {
    // Evidence recording is best-effort, exactly like the crash logging
    // around it.
  }
}
