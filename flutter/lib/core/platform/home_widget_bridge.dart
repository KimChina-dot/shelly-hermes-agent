import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Dart side of the Android home-screen widget bridge (PHASE 42).
///
/// Native side lives in `android/app/src/main/kotlin/.../MainActivity.kt`
/// (channel `dev.shelly/hermes_widget`) and `HomeWidgetProvider.kt`, which
/// renders the widget from a snapshot persisted in the
/// `shelly.widget.state` SharedPreferences.
///
/// Two flows:
/// 1. Widget tap: MainActivity receives the `shelly_action=open` extra and
///    either pushes an `action` event over the channel or caches it until
///    the Dart handler registers; the cached copy is pulled via
///    `takePendingAction` right after [register].
/// 2. App -> widget: [pushUpdate] asks the native side to persist the last
///    conversation title/count and repaint every placed widget.
///
/// Everything is defensive: on web the bridge never touches the channel and
/// on hosts without the native handler (desktop dev, unmocked tests) the
/// resulting MissingPluginException is swallowed, so it degrades to a no-op.
class HomeWidgetBridge {
  HomeWidgetBridge();

  static const MethodChannel _channel = MethodChannel('dev.shelly/hermes_widget');

  /// Extra value MainActivity forwards when the widget is tapped.
  static const String actionOpen = 'open';

  void Function(String action)? _onAction;

  /// Registers [onAction] for widget tap events and drains any action that
  /// fired before the Dart handler was registered (cached on the native
  /// side). Safe to call on every host; a no-op on web.
  void register(void Function(String action) onAction) {
    if (kIsWeb) return;
    _onAction = onAction;
    _channel.setMethodCallHandler(_handle);
    unawaited(_drainPending());
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'action') return null;
    _deliver(call.arguments);
    return null;
  }

  void _deliver(Object? action) {
    final callback = _onAction;
    if (action is String && action.isNotEmpty && callback != null) {
      callback(action);
    }
  }

  Future<void> _drainPending() async {
    try {
      final pending = await _channel.invokeMethod<dynamic>('takePendingAction');
      _deliver(pending);
    } on MissingPluginException {
      // No native handler on this host: stay a no-op.
    } catch (_) {
      // Widget housekeeping must never break the app.
    }
  }

  /// Best-effort widget refresh: persists the last conversation title and
  /// the conversation count on the native side and repaints the widget.
  /// Errors are swallowed so callers can fire-and-forget.
  Future<void> pushUpdate({
    required String lastConversationTitle,
    required int conversationCount,
  }) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('pushUpdate', <String, dynamic>{
        'lastConversationTitle': lastConversationTitle,
        'conversationCount': conversationCount,
      });
    } on MissingPluginException {
      // No native handler on this host: stay a no-op.
    } catch (_) {
      // Widget housekeeping must never break the app.
    }
  }

  /// Detaches the handler; called when the shell is disposed.
  void dispose() {
    if (!kIsWeb) _channel.setMethodCallHandler(null);
    _onAction = null;
  }
}
