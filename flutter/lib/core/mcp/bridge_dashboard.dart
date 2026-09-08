// Interactive terminal dashboard for the desktop MCP sidecar bridge. Pure
// `dart:io` (stdin/stdout + ANSI escape codes) — no third-party dependencies.
//
// The dashboard wraps a *running* [BridgeServer] and repaints at most twice
// per second:
//
//   - bridge URL, LAN addresses and the pairing token (masked by default,
//     `t` toggles masking);
//   - one status line per configured stdio server: alive / restarting / dead
//     plus tool count and restart count;
//   - the most recent tool calls.
//
// BridgeServer exposes `healthPayload()` (alive + toolCount per server) but
// no restart counter and no call log, so the dashboard derives restart counts
// by diffing consecutive health snapshots (each observed death of a child
// counts as one restart), and keeps a dashboard-local [BridgeCallLog] that
// any caller (the CLI, tests, or a future server hook) can feed via
// [BridgeDashboard.recordCall] / [BridgeDashboard.callLog].
//
// All rendering goes through an injectable [StringSink] and all keyboard
// commands through an injectable stdin line stream, so tests can drive the
// dashboard without a real terminal.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelly_hermes/core/mcp/bridge_server.dart';

// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals

/// One observed bridge tool call, as rendered in the dashboard call log.
class BridgeCallEntry {
  const BridgeCallEntry({
    required this.time,
    required this.server,
    required this.tool,
    required this.durationMs,
    required this.ok,
    this.error,
  });

  /// When the call finished.
  final DateTime time;

  /// Bridge server id the call was routed to.
  final String server;

  /// Raw MCP tool name (without the `<server>.` prefix).
  final String tool;

  /// Round-trip duration in milliseconds.
  final int durationMs;

  /// Whether the call produced a result (false = error).
  final bool ok;

  /// Error text when [ok] is false.
  final String? error;

  /// One-line rendering: `HH:mm:ss  server.tool  123ms  OK` (or `失败: …`).
  String get label {
    final status = ok ? 'OK' : '失败: ${error ?? '未知错误'}';
    return '${_hhmmss(time)}  $server.$tool  $durationMs ms  $status';
  }
}

String _hhmmss(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

String _two(int value) => value.toString().padLeft(2, '0');

/// Dashboard-local tool-call log. The bridge server itself has no call
/// observability hook (and must not be modified for the dashboard), so this
/// ring buffer is fed externally — via [BridgeDashboard.recordCall] — and the
/// dashboard renders its tail and dumps it on demand (`l`).
class BridgeCallLog {
  BridgeCallLog({this.maxEntries = 500});

  /// Maximum number of retained entries (oldest are dropped first).
  final int maxEntries;

  final List<BridgeCallEntry> _entries = [];

  /// Unmodifiable snapshot of all retained entries, oldest first.
  List<BridgeCallEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

  /// Records one finished call.
  void record({
    required String server,
    required String tool,
    required int durationMs,
    required bool ok,
    String? error,
    DateTime? time,
  }) {
    _entries.add(BridgeCallEntry(
      time: time ?? DateTime.now(),
      server: server,
      tool: tool,
      durationMs: durationMs,
      ok: ok,
      error: error,
    ));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }
}

/// Interactive terminal UX around a running [BridgeServer].
///
/// Keyboard commands: `q` quit (graceful server stop), `t` toggle token
/// masking, `r` force refresh, `l` dump the full call log. Any other input
/// simply requests a (throttled) repaint; closing the input stream quits.
class BridgeDashboard {
  BridgeDashboard({
    required BridgeServer server,
    required String token,
    StringSink? output,
    Stream<String>? inputLines,
    DateTime Function()? clock,
    Future<List<String>> Function()? lanAddressProvider,
    this.refreshInterval = defaultRefreshInterval,
    BridgeCallLog? callLog,
  })  : _server = server,
        _token = token,
        _out = output ?? stdout,
        _input = inputLines ??
            stdin.transform(utf8.decoder).transform(const LineSplitter()),
        _clock = clock ?? DateTime.now,
        _lanAddressProvider = lanAddressProvider,
        _callLog = callLog ?? BridgeCallLog();

  /// Time between automatic repaints — 500 ms keeps the loop at the promised
  /// "at most 2 repaints per second".
  static const Duration defaultRefreshInterval = Duration(milliseconds: 500);

  /// How many recent calls the framed view shows.
  static const int recentCallLimit = 10;

  static const String _clearScreen = '\x1b[2J\x1b[H';

  static const String _maskedToken = '************';

  final BridgeServer _server;
  final String _token;
  final StringSink _out;
  final Stream<String> _input;
  final DateTime Function() _clock;
  final Future<List<String>> Function()? _lanAddressProvider;
  final BridgeCallLog _callLog;

  final Duration refreshInterval;

  Completer<void>? _quitCompleter;
  Timer? _ticker;
  Timer? _pendingRepaint;
  StreamSubscription<String>? _inputSub;
  bool _stopping = false;
  bool _dirty = false;
  bool _showToken = false;
  int _repaintCount = 0;
  DateTime _lastPaint = DateTime(0);
  List<String> _lanUrls = const <String>[];

  // Observed per-server state, derived from health snapshots.
  final List<String> _serverOrder = <String>[];
  final Map<String, String> _serverNames = <String, String>{};
  final Map<String, bool> _aliveNow = <String, bool>{};
  final Map<String, bool> _everAlive = <String, bool>{};
  final Map<String, int> _toolCounts = <String, int>{};
  final Map<String, int> _restartCounts = <String, int>{};

  /// The call log this dashboard renders; feed it from the CLI, tests, or a
  /// future server-side hook.
  BridgeCallLog get callLog => _callLog;

  /// Number of frames painted so far (used by tests to verify throttling).
  int get repaintCount => _repaintCount;

  /// Convenience hook so external callers (e.g. a server-side observability
  /// shim) can record finished tool calls without touching [_callLog] directly.
  void recordCall({
    required String server,
    required String tool,
    required int durationMs,
    required bool ok,
    String? error,
  }) {
    _callLog.record(
      server: server,
      tool: tool,
      durationMs: durationMs,
      ok: ok,
      error: error,
    );
  }

  /// Runs the refresh + input loop until the user quits (`q`) or the input
  /// stream closes. Stops the wrapped server gracefully before returning.
  Future<void> run() async {
    if (_quitCompleter != null) {
      throw StateError('BridgeDashboard 已经在运行');
    }
    _quitCompleter = Completer<void>();
    _stopping = false;
    _dirty = false;
    // Silent: populate addresses before the first frame, without painting.
    await _refreshLan(repaint: false);
    _paint();
    _ticker = Timer.periodic(refreshInterval, (_) => _requestRepaint());
    _inputSub = _input.listen(
      _onInputLine,
      onDone: _requestQuit,
      onError: (Object _) => _requestQuit(),
      cancelOnError: true,
    );
    await _quitCompleter!.future;
    _quitCompleter = null;
  }

  /// Requests a graceful quit from outside the input loop (e.g. SIGINT).
  void requestQuit() => _requestQuit();

  // ---------------------------------------------------------------------------
  // Input handling
  // ---------------------------------------------------------------------------

  void _onInputLine(String line) {
    switch (line.trim().toLowerCase()) {
      case 'q' || 'quit' || 'exit':
        _requestQuit();
      case 't':
        _showToken = !_showToken;
        _requestRepaint(force: true);
      case 'r':
        _requestRepaint(force: true);
      case 'l':
        _dumpCallLog();
        _requestRepaint();
      default:
        _requestRepaint();
    }
  }

  void _requestQuit() {
    final completer = _quitCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete(_shutdown());
  }

  Future<void> _shutdown() async {
    if (_stopping) return;
    _stopping = true;
    _ticker?.cancel();
    _ticker = null;
    _pendingRepaint?.cancel();
    _pendingRepaint = null;
    await _inputSub?.cancel();
    _out.write('\n');
    _out.writeln('正在停止桥接服务…');
    try {
      await _server.stop();
    } catch (_) {
      // Shutdown must never throw out of the dashboard.
    }
    _out.writeln('桥接服务已停止,仪表盘退出。');
  }

  // ---------------------------------------------------------------------------
  // Repaint loop (throttled to refreshInterval, i.e. at most 2x/sec)
  // ---------------------------------------------------------------------------

  void _requestRepaint({bool force = false}) {
    if (_stopping || _quitCompleter == null) return;
    if (force) {
      _pendingRepaint?.cancel();
      _pendingRepaint = null;
      _paint();
      return;
    }
    _dirty = true;
    final elapsed = _clock().difference(_lastPaint);
    if (elapsed >= refreshInterval) {
      _paint();
    } else {
      // Coalesce: one deferred repaint at most, at the interval boundary.
      _pendingRepaint ??= Timer(refreshInterval - elapsed, () {
        _pendingRepaint = null;
        if (_dirty && !_stopping) _paint();
      });
    }
  }

  void _paint() {
    _dirty = false;
    _lastPaint = _clock();
    _repaintCount += 1;
    _observeHealth();
    unawaited(_refreshLan());
    _out.write(_frame());
  }

  /// Diffs the latest health snapshot into the observed per-server state.
  void _observeHealth() {
    Map<String, dynamic> health;
    try {
      health = _server.healthPayload();
    } catch (_) {
      return; // Keep the previous frame's state.
    }
    final servers = health['servers'];
    if (servers is! List) return;
    final order = <String>[];
    for (final entry in servers) {
      if (entry is! Map<String, dynamic>) continue;
      final id = entry['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final alive = entry['alive'] == true;
      if (_aliveNow[id] == true && !alive) {
        // The bridge respawns dead children with backoff; each observed death
        // counts as one restart.
        _restartCounts[id] = (_restartCounts[id] ?? 0) + 1;
      }
      _aliveNow[id] = alive;
      if (alive) _everAlive[id] = true;
      _toolCounts[id] =
          entry['toolCount'] is int ? entry['toolCount'] as int : 0;
      _serverNames[id] = entry['name'] as String? ?? id;
      order.add(id);
    }
    _serverOrder
      ..clear()
      ..addAll(order);
  }

  String _statusLabel(String id) {
    if (_aliveNow[id] == true) return '运行中';
    if (_everAlive[id] == true) return '重启中';
    return '已离线';
  }

  String _tokenDisplay() {
    if (_token.isEmpty) return '(未设置)';
    if (_showToken) return '$_token (按 t 隐藏)';
    return '$_maskedToken (按 t 显示)';
  }

  String _frame() {
    final buffer = StringBuffer()
      ..write(_clearScreen)
      ..writeln('Shelly MCP 桥接仪表盘')
      ..writeln('桥接地址: http://localhost:${_server.port}')
      ..write('局域网地址: ');
    if (_lanUrls.isEmpty) {
      buffer.writeln('(检测中…)');
    } else {
      buffer.writeln();
      for (final url in _lanUrls) {
        buffer.writeln('  $url');
      }
    }
    buffer
      ..writeln('配对令牌: ${_tokenDisplay()}')
      ..writeln('stdio 服务器:');
    if (_serverOrder.isEmpty) {
      buffer.writeln('  (未配置)');
    } else {
      for (final id in _serverOrder) {
        final alive = _aliveNow[id] == true;
        buffer.writeln(
          '  [${alive ? '+' : 'x'}] $id (${_serverNames[id] ?? id})'
          ' — ${_statusLabel(id)} · 工具 ${_toolCounts[id] ?? 0}'
          ' · 重启 ${_restartCounts[id] ?? 0} 次',
        );
      }
    }
    buffer.writeln('最近调用 (最多 $recentCallLimit 条):');
    final recent = _callLog.entries.reversed.take(recentCallLimit);
    if (recent.isEmpty) {
      buffer.writeln('  (暂无调用记录)');
    } else {
      for (final entry in recent) {
        buffer.writeln('  ${entry.label}');
      }
    }
    buffer
      ..writeln('-' * 46)
      ..writeln('快捷键: q 退出 · t 显隐令牌 · r 立即刷新 · l 导出完整调用日志');
    return buffer.toString();
  }

  void _dumpCallLog() {
    final entries = _callLog.entries;
    _out.write('\n');
    _out.writeln('=== 完整调用日志 (${entries.length} 条) ===');
    if (entries.isEmpty) {
      _out.writeln('(暂无调用记录)');
    } else {
      for (final entry in entries) {
        _out.writeln(entry.label);
      }
    }
    _out.writeln('=== 日志结束 ===');
  }

  // ---------------------------------------------------------------------------
  // LAN address discovery
  // ---------------------------------------------------------------------------

  Future<void> _refreshLan({bool repaint = true}) async {
    List<String> fresh;
    try {
      fresh = await (_lanAddressProvider?.call() ?? _defaultLanAddresses());
    } catch (_) {
      return; // Keep the previously known addresses.
    }
    if (_stopping) return;
    if (!_listEquals(fresh, _lanUrls)) {
      _lanUrls = fresh;
      if (repaint) _requestRepaint();
    }
  }

  Future<List<String>> _defaultLanAddresses() async {
    final port = _server.port;
    if (port == 0) return const <String>[];
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return <String>[
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (address.type == InternetAddressType.IPv4)
            'http://${address.address}:$port',
    ];
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
