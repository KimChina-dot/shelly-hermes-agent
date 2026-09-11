import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/crash/crash_log_store.dart';
import 'core/migration/migration_bootstrap.dart';
import 'core/migration/migration_prefs.dart';

Future<void> main() async {
  // Expose the Flutter semantics tree as DOM nodes so browser-based
  // verification tooling (frontend MCP, screen readers) can interact with
  // the web dev harness. No-op cost on other platforms.
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  final crashLog = await _installCrashLogging();
  await _runStartupMigration(crashLog);
  runApp(const ProviderScope(child: ShellyApp()));
}

/// Local crash capture (PHASE 41): both framework and platform errors are
/// persisted to SharedPreferences before the app runs. Failure to set this
/// up (missing prefs, storage error) must never block startup.
Future<CrashLogStore?> _installCrashLogging() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final store = CrashLogStore(prefs);
    installCrashLogging(store);
    return store;
  } catch (_) {
    // Crash recording is best-effort; startup continues either way.
    return null;
  }
}

/// v3.0 cutover (PHASE 18, plan P8): the five-stage migration runs once
/// per install between crash logging and runApp — old keys are kept as the
/// rollback anchor, every failure mode is fail-open, and the outcome lands
/// in the crash log as upgrade evidence.
Future<void> _runStartupMigration(CrashLogStore? crashLog) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await runStartupMigration(
      prefs: SharedPreferencesMigrationPrefs(prefs),
      evidence: crashLog == null
          ? null
          : (context, message) => crashLog.record(
                context: context,
                error: message,
              ),
    );
  } catch (_) {
    // Prefs unavailable (fresh install edge, storage error): the app boots
    // unmigrated; the next launch retries the idempotent run.
  }
}
