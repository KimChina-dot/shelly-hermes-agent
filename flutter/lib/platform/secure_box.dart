import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Abstraction over secret storage (model API keys). On Android this is
/// backed by the AndroidKeyStore bridge; elsewhere by plain SharedPreferences
/// (acceptable for the web dev harness, which is not a release target).
abstract interface class SecureBox {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _ChannelSecureBox implements SecureBox {
  static const _channel = MethodChannel('dev.shelly/secure_store');

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', key);

  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', key);
}

class _PrefsSecureBox implements SecureBox {
  static const _prefix = 'shelly.secure.';

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async =>
      (await _prefs()).getString('$_prefix$key');

  @override
  Future<void> write(String key, String value) async {
    final prefs = await _prefs();
    if (value.isEmpty) {
      await prefs.remove('$_prefix$key');
    } else {
      await prefs.setString('$_prefix$key', value);
    }
  }

  @override
  Future<void> delete(String key) async =>
      (await _prefs()).remove('$_prefix$key');
}

bool get _hasKeystoreBridge => !kIsWeb && Platform.isAndroid;

/// Channel-backed secure storage on Android, SharedPreferences elsewhere.
SecureBox? createSecureBox() =>
    _hasKeystoreBridge ? _ChannelSecureBox() : _PrefsSecureBox();

/// Test hook (PHASE 20): exposes the channel-backed box so the wire
/// contract against SecureStore.kt is regression-testable on hosts where
/// `Platform.isAndroid` is false. Production code uses [createSecureBox].
@visibleForTesting
SecureBox debugChannelSecureBox() => _ChannelSecureBox();
