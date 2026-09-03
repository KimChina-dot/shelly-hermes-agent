import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
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
  Future<bool> deleteFile(String path) async {
    return await _channel.invokeMethod<bool>('deleteFile', path) ?? false;
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

/// Workspace that degrades gracefully while the user has not picked a SAF
/// directory on Android: every operation lands in an in-memory sandbox
/// instead of failing with "no workspace directory picked". Once a directory
/// is granted (or found persisted from a previous run) operations flow
/// through [PlatformWorkspace]; if the platform bridge still throws (e.g.
/// a revoked grant) the sandbox answers so the app never surfaces a raw
/// PlatformException.
class ResilientWorkspace implements Workspace {
  ResilientWorkspace({PlatformWorkspace? platform, MemoryWorkspace? sandbox})
      : _platform = platform ?? PlatformWorkspace(),
        _sandbox = sandbox ?? MemoryWorkspace();

  final PlatformWorkspace _platform;
  final MemoryWorkspace _sandbox;

  /// Watched by UI banners: true once a SAF directory is authorized.
  final ValueNotifier<bool> authorized = ValueNotifier(false);

  /// Re-reads the persisted grant; call at startup and after picking.
  Future<void> refreshAuthorization() async {
    authorized.value = await _platform.hasDirectory();
  }

  /// Opens the system directory picker; on grant this workspace switches
  /// onto SAF. Returns the tree URI, or null when the user cancelled.
  Future<String?> pickDirectory() async {
    final uri = await _platform.pickDirectory();
    await refreshAuthorization();
    return uri;
  }

  Workspace get _delegate => authorized.value ? _platform : _sandbox;

  /// Runs [op] against the active delegate; a platform-side failure falls
  /// back to the sandbox so an unmounted grant never breaks the feature.
  Future<T> _guarded<T>(Future<T> Function(Workspace ws) op) async {
    try {
      return await op(_delegate);
    } on PlatformException {
      return op(_sandbox);
    }
  }

  @override
  Future<String?> readFile(String path) =>
      _guarded((ws) => ws.readFile(path));

  @override
  Future<void> writeFile(String path, String content) =>
      _guarded((ws) => ws.writeFile(path, content));

  @override
  Future<bool> deleteFile(String path) =>
      _guarded((ws) => ws.deleteFile(path));

  @override
  Future<bool> exists(String path) => _guarded((ws) => ws.exists(path));

  @override
  Future<List<String>> listFiles([String prefix = '']) =>
      _guarded((ws) => ws.listFiles(prefix));

  @override
  Future<List<String>> searchFiles(String query) =>
      _guarded((ws) => ws.searchFiles(query));
}

/// Returns the resilient workspace on Android (SAF once granted, in-memory
/// sandbox before that), the plain in-memory one elsewhere.
Workspace createWorkspace() =>
    isAndroidHost ? ResilientWorkspace() : fallbackWorkspace;
