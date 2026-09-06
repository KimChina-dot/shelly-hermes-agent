import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One locally captured crash: when it happened, which layer reported it
/// (framework or platform dispatcher), the error text and a truncated stack.
/// Entries live in a single JSON list under SharedPreferences; retention is
/// bounded by [CrashLogStore.maxEntries] and [CrashLogStore.maxStackLength].
class CrashEntry {
  const CrashEntry({
    required this.at,
    required this.context,
    required this.error,
    required this.stack,
  });

  /// Reporting layer: `'flutter'` (framework handler) or `'platform'`
  /// (platform dispatcher handler).
  final String context;
  final String error;
  final String stack;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'context': context,
        'error': error,
        'stack': stack,
      };

  static CrashEntry fromJson(Map<String, dynamic> json) => CrashEntry(
        at: json['at'] is String
            ? DateTime.tryParse(json['at'] as String) ?? DateTime.now()
            : DateTime.now(),
        context: json['context'] as String? ?? 'flutter',
        error: json['error'] as String? ?? '',
        stack: json['stack'] as String? ?? '',
      );
}

/// Local crash log (PHASE 41). Both the Flutter framework handler and the
/// platform dispatcher handler append entries to a JSON list in
/// SharedPreferences so the profile page diagnostics card can show what
/// went wrong without any network round-trip. The list is stored
/// newest-first and capped to keep the payload small.
class CrashLogStore {
  CrashLogStore(this._prefs);

  final SharedPreferences _prefs;

  static const _crashKey = 'shelly.crash.logs';

  /// Hard cap on stored entries; the newest ones win.
  static const int maxEntries = 50;

  /// Stacks longer than this are truncated before persisting.
  static const int maxStackLength = 2000;

  /// Records one crash, truncates the stack, keeps the newest
  /// [maxEntries] entries and persists.
  /// An explicit [at] is for tests; production stamps the current time.
  Future<void> record({
    required String context,
    required Object error,
    StackTrace? stack,
    DateTime? at,
  }) async {
    try {
      final entry = CrashEntry(
        context: context,
        error: error.toString(),
        stack: _truncate(stack?.toString() ?? ''),
        at: at ?? DateTime.now(),
      );
      final entries = [entry, ...loadEntries()];
      await _save(entries.length > maxEntries
          ? entries.sublist(0, maxEntries)
          : entries);
    } catch (_) {
      // Crash recording must never introduce a new failure.
    }
  }

  /// All stored entries, newest first.
  List<CrashEntry> loadEntries() {
    final raw = _prefs.getString(_crashKey);
    if (raw == null) return const [];
    try {
      return [
        for (final entry in jsonDecode(raw) as List<dynamic>)
          if (entry is Map<String, dynamic>) CrashEntry.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Drops every stored entry (profile page diagnostics card).
  Future<void> clear() => _prefs.remove(_crashKey);

  Future<void> _save(List<CrashEntry> entries) => _prefs.setString(
        _crashKey,
        jsonEncode([for (final entry in entries) entry.toJson()]),
      );
}

String _truncate(String stack) =>
    stack.length <= CrashLogStore.maxStackLength
        ? stack
        : stack.substring(0, CrashLogStore.maxStackLength);

bool _crashLoggingInstalled = false;

/// Wires [FlutterError.onError] and [PlatformDispatcher.instance.onError] to
/// record into [store] (PHASE 41). Install once at startup, before runApp:
/// the double-install guard makes repeated calls no-ops, and any previously
/// installed handlers are chained instead of discarded.
///
/// Recording itself is wrapped so a persistence failure can never throw out
/// of the handlers, and [store.record] never completes with an error.
///
/// Returns a detach callback (used by tests to restore the original
/// handlers); it is a no-op when this call was skipped by the guard.
void Function() installCrashLogging(CrashLogStore store) {
  if (_crashLoggingInstalled) return () {};
  _crashLoggingInstalled = true;

  final previousFlutterHandler = FlutterError.onError;
  final previousPlatformHandler = PlatformDispatcher.instance.onError;

  FlutterError.onError = (details) {
    try {
      unawaited(store.record(
        context: 'flutter',
        error: details.exception,
        stack: details.stack,
      ));
    } catch (_) {
      // Crash recording must never introduce a new failure.
    }
    previousFlutterHandler?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    try {
      unawaited(store.record(
        context: 'platform',
        error: error,
        stack: stack,
      ));
    } catch (_) {
      // Crash recording must never introduce a new failure.
    }
    return previousPlatformHandler?.call(error, stack) ?? true;
  };

  return () {
    if (!_crashLoggingInstalled) return;
    FlutterError.onError = previousFlutterHandler;
    PlatformDispatcher.instance.onError = previousPlatformHandler;
    _crashLoggingInstalled = false;
  };
}

/// Reactive access for the profile page diagnostics card.
final crashLogProvider = FutureProvider<CrashLogStore>((ref) async {
  return CrashLogStore(await SharedPreferences.getInstance());
});
