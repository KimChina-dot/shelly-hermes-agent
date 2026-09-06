import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/lan/lan_companion_server.dart';
import '../core/models.dart';
import 'settings_store.dart';
import 'update_check.dart';

/// Persistence for the LAN companion toggle and pairing token (PHASE 42),
/// backed by SharedPreferences like every other store in this folder.
class LanCompanionStore {
  LanCompanionStore(this._prefs);

  final SharedPreferences _prefs;

  static const enabledKey = 'shelly.lan.enabled';
  static const tokenKey = 'shelly.lan.token';

  /// Off by default: serving conversation data over the LAN is opt-in.
  bool loadEnabled() => _prefs.getBool(enabledKey) ?? false;

  Future<void> setEnabled(bool enabled) => _prefs.setBool(enabledKey, enabled);

  /// The pairing token every companion request must present. Generated once
  /// (8 alphanumeric characters) on first read and persisted forever after.
  Future<String> loadToken() async {
    final existing = _prefs.getString(tokenKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final token = generateToken();
    await _prefs.setString(tokenKey, token);
    return token;
  }

  /// Random alphanumeric pairing code; cryptographically seeded by default
  /// and length-injectable for tests.
  static String generateToken({int length = 8, Random? random}) {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = random ?? Random.secure();
    return List.generate(
      length,
      (_) => alphabet[rng.nextInt(alphabet.length)],
    ).join();
  }
}

/// LAN IPv4 addresses (e.g. `192.168.1.8`) for the pairing hint. Empty on
/// hosts without usable interfaces (and on the web dev harness, where
/// `dart:io` networking is unavailable).
Future<List<String>> lanIPv4Addresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback) address.address,
    ];
  } catch (_) {
    return const [];
  }
}

/// UI-facing state of the LAN companion: the persisted toggle and token,
/// the bound port while the server runs, the LAN addresses to pair against
/// and the last failure (surfaced instead of thrown — the companion must
/// never crash the app).
class LanCompanionState {
  const LanCompanionState({
    this.enabled = false,
    this.token = '',
    this.port,
    this.addresses = const [],
    this.error,
  });

  final bool enabled;
  final String token;

  /// Actually bound port while the server runs; null when stopped.
  final int? port;

  /// LAN IPv4 addresses shown for pairing.
  final List<String> addresses;

  /// Last start/persist failure, human-readable; null while healthy.
  final String? error;

  bool get running => port != null;

  LanCompanionState copyWith({
    bool? enabled,
    String? token,
    int? port,
    List<String>? addresses,
    String? error,
    bool clearPort = false,
    bool clearError = false,
  }) =>
      LanCompanionState(
        enabled: enabled ?? this.enabled,
        token: token ?? this.token,
        port: clearPort ? null : (port ?? this.port),
        addresses: addresses ?? this.addresses,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Starts/stops the companion server when the toggle changes. Reads the
/// persisted toggle once at construction and restores the server after a
/// process restart. Every failure is best-effort: it lands in
/// [LanCompanionState.error] instead of propagating.
class LanCompanionController extends StateNotifier<LanCompanionState> {
  LanCompanionController(this._ref) : super(const LanCompanionState()) {
    _restore();
  }

  final Ref _ref;
  LanCompanionServer? _server;
  LanCompanionStore? _store;

  /// Guards against a stale async start finishing after a newer toggle.
  int _generation = 0;

  /// Loads prefs, picks up the persisted token/toggle and restarts the
  /// server when it was left enabled.
  Future<void> _restore() async {
    try {
      final store = await _ensureStore();
      final token = await store.loadToken();
      final enabled = store.loadEnabled();
      if (!mounted) return;
      state = state.copyWith(token: token, enabled: enabled);
      if (enabled) {
        await start();
      }
    } catch (error) {
      if (mounted) {
        state = state.copyWith(error: '初始化失败:$error');
      }
    }
  }

  Future<LanCompanionStore> _ensureStore() async {
    final existing = _store;
    if (existing != null) return existing;
    final store = LanCompanionStore(await SharedPreferences.getInstance());
    _store = store;
    return store;
  }

  /// Enables/disables the companion, persists the toggle and starts/stops
  /// the server. The switch flips immediately so the UI never lags.
  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled, clearError: true);
    try {
      await (await _ensureStore()).setEnabled(enabled);
    } catch (_) {
      // Persistence is best-effort; the runtime toggle still applies.
    }
    if (enabled) {
      await start();
    } else {
      await stop();
    }
  }

  /// Binds the companion server on the default port. Bind failures and
  /// loader exceptions land in the state instead of throwing.
  Future<void> start() async {
    final generation = ++_generation;
    state = state.copyWith(clearError: true);
    try {
      final store = await _ensureStore();
      final token =
          state.token.isNotEmpty ? state.token : await store.loadToken();
      final server = LanCompanionServer(
        port: LanCompanionServer.defaultPort,
        token: token,
        version: _version(),
        modelId: _modelId,
        loadConversations: _conversations,
        loadCheckpoint: _checkpoint,
      );
      final bound = await server.start();
      if (!mounted || generation != _generation) {
        // A newer toggle happened meanwhile — undo this start.
        await server.stop();
        return;
      }
      if (bound == null) {
        _server = null;
        state = state.copyWith(
          error: '端口 ${LanCompanionServer.defaultPort} 绑定失败,可能已被占用',
          clearPort: true,
        );
        return;
      }
      _server = server;
      final addresses = await lanIPv4Addresses();
      if (!mounted || generation != _generation) return;
      state = state.copyWith(port: bound, addresses: addresses);
    } catch (error) {
      if (mounted) {
        state = state.copyWith(error: '启动失败:$error', clearPort: true);
      }
    }
  }

  /// Stops the server; idempotent and failure-proof.
  Future<void> stop() async {
    final generation = ++_generation;
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.stop();
      } catch (_) {}
    }
    if (!mounted || generation != _generation) return;
    state = state.copyWith(clearPort: true);
  }

  @override
  void dispose() {
    _generation += 1;
    final server = _server;
    _server = null;
    if (server != null) {
      unawaited(server.stop());
    }
    super.dispose();
  }

  // --- Injected server collaborators; each one is failure-proof because it
  // runs inside the server request loop. ---

  String _version() {
    try {
      return _ref.read(updateCheckProvider).valueOrNull?.currentVersion ?? '';
    } catch (_) {
      return '';
    }
  }

  String _modelId() {
    try {
      return _ref.read(settingsStoreProvider).valueOrNull?.modelConfig.model ??
          '';
    } catch (_) {
      return '';
    }
  }

  List<Map<String, dynamic>> _conversations() {
    try {
      final store = _ref.read(settingsStoreProvider).valueOrNull;
      if (store == null) return const [];
      return [for (final conversation in store.loadConversations())
        conversation.toJson()];
    } catch (_) {
      return const [];
    }
  }

  AgentCheckpoint? _checkpoint(String conversationId) {
    try {
      return _ref
          .read(settingsStoreProvider)
          .valueOrNull
          ?.loadCheckpoint(conversationId);
    } catch (_) {
      return null;
    }
  }
}

/// Reactive access for the profile page. Keep-alive on purpose: once the
/// companion is enabled the server must survive page navigation.
final lanCompanionProvider =
    StateNotifierProvider<LanCompanionController, LanCompanionState>(
  (ref) => LanCompanionController(ref),
);
