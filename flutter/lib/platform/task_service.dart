import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'platform_workspace.dart' show isAndroidHost;

/// Foreground-service control for running agent tasks on Android. All calls
/// are no-ops on other hosts so the same code runs in tests and on web.
class TaskService {
  static const _channel = MethodChannel('dev.shelly/task_service');

  /// Test hook (PHASE 20): forces the guarded invoke path on so the wire
  /// contract against MainActivity.kt is regression-testable on hosts where
  /// `Platform.isAndroid` is false. Production code never sets it.
  @visibleForTesting
  static bool debugUseChannel = false;

  /// Calls reach the native side on the real Android host, or in a test that
  /// forced the channel on. Otherwise every entry point stays a no-op.
  static bool get _shouldInvoke => isAndroidHost || debugUseChannel;

  static Future<void> start() async {
    if (!_shouldInvoke) return;
    try {
      await _channel.invokeMethod<void>('start');
    } on PlatformException {
      // Service start can fail when notification permission is missing;
      // the task itself is unaffected, so we swallow the error.
    }
  }

  static Future<void> stop() async {
    if (!_shouldInvoke) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already stopped — nothing to do.
    }
  }

  static Future<void> requestNotificationPermission() async {
    if (!_shouldInvoke) return;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on PlatformException {
      // Permission prompt unavailable; the user can grant it from settings.
    }
  }
}
