import 'package:flutter/services.dart';

import 'platform_workspace.dart' show isAndroidHost;

/// Foreground-service control for running agent tasks on Android. All calls
/// are no-ops on other hosts so the same code runs in tests and on web.
class TaskService {
  static const _channel = MethodChannel('dev.shelly/task_service');

  static Future<void> start() async {
    if (!isAndroidHost) return;
    try {
      await _channel.invokeMethod<void>('start');
    } on PlatformException {
      // Service start can fail when notification permission is missing;
      // the task itself is unaffected, so we swallow the error.
    }
  }

  static Future<void> stop() async {
    if (!isAndroidHost) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Already stopped — nothing to do.
    }
  }

  static Future<void> requestNotificationPermission() async {
    if (!isAndroidHost) return;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on PlatformException {
      // Permission prompt unavailable; the user can grant it from settings.
    }
  }
}
