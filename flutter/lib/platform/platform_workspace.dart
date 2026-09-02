import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../core/tools/workspace.dart';

const _channelName = 'dev.shelly/workspace';

/// Returns true when the running host is the Android app with the native
/// SAF bridge compiled in.
bool get isAndroidHost => !kIsWeb && Platform.isAndroid;

/// Workspace backed by a user-picked SAF directory tree on Android.
/// All operations delegate to the native side, which resolves paths by
/// walking child documents from the persisted tree root.
class PlatformWorkspace implements Workspace {
  PlatformWorkspace([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(_channelName);

  final MethodChannel _channel;

  /// Opens the system directory picker and persists the grant.
  /// Returns the tree URI, or null when the user cancelled.
  Future<String?> pickDirectory() async {
    try {
      return await _channel.invokeMethod<String>('pickDirectory');
    } on PlatformException {
      return null;
    }
  }

  Future<bool> hasDirectory() async {
    try {
      return await _channel.invokeMethod<bool>('hasDirectory') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> forgetDirectory() async {
    try {
      await _channel.invokeMethod<void>('forgetDirectory');
    } on PlatformException {
      // Nothing persisted — nothing to forget.
    }
  }

  @override
  Future<String?> readFile(String path) async {
    return _channel.invokeMethod<String>('readFile', path);
  }

  @override
  Future<void> writeFile(String path, String content) {
    return _channel.invokeMethod<void>('writeFile', {
      'path': path,
      'content': content,
    });
  }

  @override
  Future<bool> exists(String path) async {
    return await readFile(path) != null;
  }

  @override
  Future<List<String>> listFiles([String prefix = '']) async {
    final all = await _channel.invokeMethod<List<dynamic>>('listFiles', prefix) ?? const [];
    return [
      for (final item in all)
        if ((item as String).contains(prefix)) item,
    ]..sort();
  }

  @override
  Future<List<String>> searchFiles(String query) async {
    if (query.isEmpty) return const [];
    final needle = query.toLowerCase();
    final matches = <String>[];
    for (final path in await listFiles()) {
      if (path.toLowerCase().contains(needle)) {
        matches.add(path);
        continue;
      }
      final content = await readFile(path);
      if (content != null && content.toLowerCase().contains(needle)) {
        matches.add(path);
      }
    }
    matches.sort();
    return matches;
  }
}

/// Workspace used on non-Android hosts (web dev harness, VM tests).
final fallbackWorkspace = MemoryWorkspace();

/// Returns the SAF-backed workspace on Android, the in-memory one elsewhere.
Workspace createWorkspace() =>
    isAndroidHost ? PlatformWorkspace() : fallbackWorkspace;
