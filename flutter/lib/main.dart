import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/crash/crash_log_store.dart';

Future<void> main() async {
  // Expose the Flutter semantics tree as DOM nodes so browser-based
  // verification tooling (frontend MCP, screen readers) can interact with
  // the web dev harness. No-op cost on other platforms.
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  await _installCrashLogging();
  runApp(const ProviderScope(child: ShellyApp()));
}

/// Local crash capture (PHASE 41): both framework and platform errors are
/// persisted to SharedPreferences before the app runs. Failure to set this
/// up (missing prefs, storage error) must never block startup.
Future<void> _installCrashLogging() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    installCrashLogging(CrashLogStore(prefs));
  } catch (_) {
    // Crash recording is best-effort; startup continues either way.
  }
}
