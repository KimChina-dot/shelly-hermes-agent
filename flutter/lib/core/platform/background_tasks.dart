import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Dart side of the Android background-wake bridge for scheduled tasks
/// (PHASE 45).
///
/// Native side lives in `android/app/src/main/kotlin/.../MainActivity.kt`
/// (channel `dev.shelly/bg_tasks`) and `BackgroundTaskWorker.kt`, a
/// WorkManager `CoroutineWorker` that counts due entries in the
/// `shelly.sched.bgstate` SharedPreferences (written by Dart) and posts a
/// wake-up notification when any are overdue.
///
/// Two flows:
/// 1. Schedule: [scheduleWorkChecks] asks the native side to enqueue a
///    periodic WorkManager job ("shelly-bg-checks") that re-runs the worker
///    every [intervalMinutes] so overdue tasks wake the user even when the
///    app itself was swiped away. [cancel] removes the periodic job.
/// 2. Catch-up: tapping the notification launches MainActivity with the
///    `shelly_bg_catchup` extra; the native side either pushes a `catchup`
///    event over the channel or caches it until the Dart handler registers —
///    the cached copy is drained via `takePendingCatchup` right after
///    [handlePendingCatchup].
///
/// Everything is defensive: on web the bridge never touches the channel and
/// on hosts without the native handler (desktop dev, unmocked tests) the
/// resulting MissingPluginException is swallowed, so it degrades to a no-op.
class BackgroundTaskBridge {
  BackgroundTaskBridge();

  static const MethodChannel _channel = MethodChannel('dev.shelly/bg_tasks');

  void Function()? _onCatchup;

  /// Registers [onCatchup] for notification-tap catch-up events and drains
  /// any event that fired before the Dart handler registered (cached on the
  /// native side). Safe to call on every host; a no-op on web.
  void handlePendingCatchup(void Function() onCatchup) {
    if (kIsWeb) return;
    _onCatchup = onCatchup;
    _channel.setMethodCallHandler(_handle);
    unawaited(_drainPending());
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'catchup') return null;
    final callback = _onCatchup;
    if (callback != null) callback();
    return null;
  }

  Future<void> _drainPending() async {
    try {
      final pending = await _channel.invokeMethod<dynamic>('takePendingCatchup');
      if (pending is bool && pending && _onCatchup != null) _onCatchup!();
    } on MissingPluginException {
      // No native handler on this host: stay a no-op.
    } catch (_) {
      // Background housekeeping must never break the app.
    }
  }

  /// Best-effort: asks the native side to enqueue (or re-arm) the periodic
  /// WorkManager job that wakes the user when scheduled tasks come due.
  /// Errors are swallowed so callers can fire-and-forget.
  Future<void> scheduleWorkChecks({required int intervalMinutes}) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('schedule', <String, dynamic>{
        'intervalMinutes': intervalMinutes,
      });
    } on MissingPluginException {
      // No native handler on this host: stay a no-op.
    } catch (_) {
      // Scheduling the wake-ups must never break the app.
    }
  }

  /// Mirrors the runnable schedule into native prefs (key
  /// `shelly.sched.bgstate`) so the WorkManager worker can count due tasks
  /// without reaching Dart. [tasks] is the raw JSON-able list of
  /// {id, prompt, at(epochMs), repeat}; empty clears the mirror. Best-effort.
  Future<void> pushState(List<Map<String, dynamic>> tasks) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('pushState', <String, dynamic>{
        'tasks': tasks,
      });
    } on MissingPluginException {
      // No native handler on this host: stay a no-op.
    } catch (_) {
      // Background housekeeping must never break the app.
    }
  }

  /// Best-effort: cancels the periodic WorkManager job. Errors are swallowed
  /// so callers can fire-and-forget.
  Future<void> cancel() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // No native handler on this host: stay a no-op.
    } catch (_) {
      // Background housekeeping must never break the app.
    }
  }

  /// Detaches the handler; called when the shell is disposed.
  void dispose() {
    if (!kIsWeb) _channel.setMethodCallHandler(null);
    _onCatchup = null;
  }
}
