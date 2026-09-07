import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals

/// One stdio MCP server definition from the bridge config file. The bridge
/// spawns `command args…` on the desktop and exposes its tools over LAN HTTP.
class BridgeStdioServerDef {
  const BridgeStdioServerDef({
    required this.id,
    required this.name,
    required this.command,
    this.args = const [],
    this.env = const {},
  });

  final String id;
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'command': command,
        'args': args,
        'env': env,
      };

  static BridgeStdioServerDef fromJson(Map<String, dynamic> json) =>
      BridgeStdioServerDef(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        command: json['command'] as String? ?? '',
        args: [
          for (final arg in (json['args'] as List<dynamic>? ?? const []))
            arg.toString(),
        ],
        env: {
          for (final entry
              in ((json['env'] as Map<dynamic, dynamic>?) ?? const {}).entries)
            entry.key.toString(): entry.value.toString(),
        },
      );
}

/// Bridge configuration: the stdio servers to spawn plus the shared access
/// token the phone app must present on every request.
class BridgeConfig {
  const BridgeConfig({required this.servers, this.token = ''});

  final List<BridgeStdioServerDef> servers;
  final String token;

  static BridgeConfig fromJsonList(
    List<dynamic> json, {
    String token = '',
  }) =>
      BridgeConfig(
        servers: [
          for (final entry in json)
            if (entry is Map<String, dynamic>)
              BridgeStdioServerDef.fromJson(entry),
        ],
        token: token,
      );
}

/// A spawned child process as the bridge sees it. Real processes and test
/// fakes both speak line-delimited JSON: requests go out through [writeLine],
/// responses arrive on [stdoutLines].
abstract interface class BridgeProcess {
  /// JSON-RPC responses (and any log noise) emitted by the child.
  Stream<String> get stdoutLines;

  /// Writes one line (JSON-RPC request or notification) to the child stdin.
  void writeLine(String line);

  /// Terminates the child process.
  void kill();

  /// Completes when the child process exits.
  Future<void> get done;
}

/// Spawns one stdio server. Injectable so tests can hand out controllable
/// fakes instead of real processes.
typedef BridgeProcessSpawner = Future<BridgeProcess> Function(
  BridgeStdioServerDef def,
);

/// Domain-level bridge failure: the child answered a JSON-RPC error, died
/// mid-call, or the call timed out. Rendered as `{ok:false,error}` with HTTP
/// 200 so callers can show the reason directly.
class BridgeServerException implements Exception {
  BridgeServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Desktop sidecar: spawns stdio MCP servers, performs the JSON-RPC
/// handshake, and serves their tools over LAN HTTP so the phone app can use
/// them. No third-party dependencies — raw `dart:io` only.
class BridgeServer {
  BridgeServer({
    required BridgeConfig config,
    BridgeProcessSpawner? spawner,
    DateTime Function()? clock,
    this.handshakeTimeout = const Duration(seconds: 30),
    this.callTimeout = const Duration(seconds: 60),
    this.restartBackoffBase = const Duration(seconds: 2),
    this.restartBackoffMax = const Duration(minutes: 1),
  })  : _config = config,
        _spawner = spawner ?? _spawnReal,
        _clock = clock ?? DateTime.now;

  final BridgeConfig _config;
  final BridgeProcessSpawner _spawner;
  final DateTime Function() _clock;

  /// How long the initialize → tools/list handshake may take.
  final Duration handshakeTimeout;

  /// How long a single tools/call round-trip may take.
  final Duration callTimeout;

  /// Base delay for the restart-on-death backoff (`base · 2^failures`).
  final Duration restartBackoffBase;

  /// Upper bound for the restart backoff.
  final Duration restartBackoffMax;

  static const _protocolVersion = '2025-03-26';

  final Map<String, _ServerState> _states = {};
  HttpServer? _http;
  bool _stopping = false;

  /// Port the HTTP listener bound (0 until [start] succeeds).
  int get port => _http?.port ?? 0;

  bool get isRunning => _http != null;

  /// Spawns and handshakes every configured server (in parallel), then binds
  /// the HTTP listener. A failing server never blocks startup: it is marked
  /// not-alive and retried with backoff.
  Future<void> start({InternetAddress? address, int port = 8766}) async {
    _stopping = false;
    for (final def in _config.servers) {
      if (def.id.isEmpty || _states.containsKey(def.id)) continue;
      final state = _ServerState(def);
      _states[def.id] = state;
    }
    await Future.wait([
      for (final state in _states.values) _spawnAndHandshake(state),
    ]);
    _http = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _http!.listen(_handle, onError: (Object _) {});
  }

  /// Kills every child, cancels restart timers, closes the listener.
  Future<void> stop() async {
    _stopping = true;
    for (final state in _states.values) {
      state.restartTimer?.cancel();
      state.restartTimer = null;
      _failPending(state, '桥接服务已停止');
      state.stdoutSub?.cancel();
      state.stdoutSub = null;
      state.process?.kill();
      state.alive = false;
    }
    final http = _http;
    _http = null;
    await http?.close(force: true);
  }

  // ---------------------------------------------------------------------------
  // Child process lifecycle
  // ---------------------------------------------------------------------------

  static Future<BridgeProcess> _spawnReal(BridgeStdioServerDef def) async {
    final process = await Process.start(
      def.command,
      def.args,
      environment: def.env,
    );
    return _IoProcess(process);
  }

  Future<void> _spawnAndHandshake(_ServerState state) async {
    if (_stopping) return;
    BridgeProcess? process;
    try {
      process = await _spawner(state.def);
      state.attach(process);
      state.startedAt = _clock();
      _listenStdout(state, process);
      _watchExit(state, process);
      await _handshake(state);
      state.alive = true;
      state.failures = 0;
    } catch (error) {
      state.alive = false;
      state.detach();
      process?.kill();
      _scheduleRestart(state, wasStable: false, reason: '$error');
    }
  }

  /// Minimal MCP handshake over line-delimited JSON: initialize →
  /// notifications/initialized → tools/list (cached).
  Future<void> _handshake(_ServerState state) async {
    await _request(
      state,
      'initialize',
      {
        'protocolVersion': _protocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'shelly-bridge', 'version': '2.2.0'},
      },
      timeout: handshakeTimeout,
    );
    state.process!.writeLine(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    }));
    final listed = await _request(
      state,
      'tools/list',
      <String, dynamic>{},
      timeout: handshakeTimeout,
    );
    final tools = listed['tools'];
    state.tools = [
      if (tools is List)
        for (final tool in tools)
          if (tool is Map<String, dynamic> &&
              tool['name'] is String &&
              (tool['name'] as String).isNotEmpty)
            tool,
    ];
  }

  void _watchExit(_ServerState state, BridgeProcess process) {
    unawaited(process.done.then((_) {
      if (_stopping || state.process != process) return;
      state.alive = false;
      _failPending(state, 'MCP 服务器 ${state.def.id} 已退出');
      _scheduleRestart(state, wasStable: _wasStable(state), reason: 'exited');
    }));
  }

  bool _wasStable(_ServerState state) {
    final startedAt = state.startedAt;
    if (startedAt == null) return false;
    return _clock().difference(startedAt) >= restartBackoffMax;
  }

  /// Schedules a best-effort respawn with exponential backoff. A process
  /// that stayed alive for at least [restartBackoffMax] counts as stable and
  /// resets the failure counter first.
  void _scheduleRestart(
    _ServerState state, {
    required bool wasStable,
    required String reason,
  }) {
    if (_stopping) return;
    if (wasStable) state.failures = 0;
    // Exponential backoff: base · 2^failures, capped at restartBackoffMax.
    final exponent = state.failures > 10 ? 10 : state.failures;
    final scaled = restartBackoffBase * (1 << exponent);
    state.failures += 1;
    final delay =
        scaled > restartBackoffMax ? restartBackoffMax : scaled;
    state.restartTimer?.cancel();
    state.restartTimer = Timer(delay, () => _spawnAndHandshake(state));
  }

  // ---------------------------------------------------------------------------
  // JSON-RPC over stdio
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _request(
    _ServerState state,
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final process = state.process;
    if (process == null) {
      throw BridgeServerException('MCP 服务器 ${state.def.id} 不可用');
    }
    final id = state.nextId++;
    final completer = Completer<Map<String, dynamic>>();
    state.pending[id] = completer;
    process.writeLine(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    try {
      final response = await completer.future
          .timeout(timeout ?? callTimeout);
      return _unwrap(response);
    } on TimeoutException {
      throw BridgeServerException('MCP 服务器 ${state.def.id} 响应超时');
    } finally {
      state.pending.remove(id);
    }
  }

  Map<String, dynamic> _unwrap(Map<String, dynamic> response) {
    final error = response['error'];
    if (error != null) {
      final message =
          error is Map<String, dynamic> ? error['message'] ?? error : error;
      throw BridgeServerException('MCP 错误:$message');
    }
    final result = response['result'];
    return result is Map<String, dynamic> ? result : <String, dynamic>{};
  }

  void _listenStdout(_ServerState state, BridgeProcess process) {
    state.stdoutSub?.cancel();
    state.stdoutSub = process.stdoutLines.listen(
      (line) => _onStdoutLine(state, line),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _onStdoutLine(_ServerState state, String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return; // log noise from the child
    }
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'];
    if (id is int) {
      final completer = state.pending.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(decoded);
      }
    }
  }

  void _failPending(_ServerState state, String message) {
    final pending = Map<int, Completer<Map<String, dynamic>>>.of(state.pending);
    state.pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(BridgeServerException(message));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP surface
  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    try {
      if (!_authorized(request)) {
        await _sendJson(request, HttpStatus.unauthorized,
            {'ok': false, 'error': 'unauthorized'});
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        await _sendJson(request, HttpStatus.ok, healthPayload());
      } else if (request.method == 'POST' && path == '/list_tools') {
        await _drainBody(request);
        await _sendJson(request, HttpStatus.ok, {
          'ok': true,
          'payload': {'tools': catalog()},
        });
      } else if (request.method == 'POST' && path == '/call_tool') {
        await _handleCallTool(request);
      } else {
        await _sendJson(
          request,
          HttpStatus.notFound,
          {'ok': false, 'error': 'not found: ${request.method} $path'},
        );
      }
    } catch (error) {
      try {
        await _sendJson(request, HttpStatus.internalServerError,
            {'ok': false, 'error': 'internal error: $error'});
      } catch (_) {
        // Client already gone or response half-written; nothing to report.
      }
    }
  }

  Future<void> _handleCallTool(HttpRequest request) async {
    Map<String, dynamic> body;
    try {
      final raw = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('body must be a JSON object');
      }
      body = decoded;
    } on FormatException {
      await _sendJson(request, HttpStatus.badRequest,
          {'ok': false, 'error': 'invalid JSON body'});
      return;
    }
    final serverId = body['server'];
    final toolName = body['tool'];
    if (serverId is! String || toolName is! String || serverId.isEmpty) {
      await _sendJson(request, HttpStatus.badRequest,
          {'ok': false, 'error': '"server" and "tool" are required strings'});
      return;
    }
    final state = _states[serverId];
    if (state == null) {
      await _sendJson(request, HttpStatus.notFound,
          {'ok': false, 'error': 'unknown server: $serverId'});
      return;
    }
    final arguments = body['arguments'];
    final args =
        arguments is Map<String, dynamic> ? arguments : <String, dynamic>{};
    if (!state.alive) {
      await _sendJson(request, HttpStatus.ok,
          {'ok': false, 'error': 'MCP 服务器 $serverId 不可用'});
      return;
    }
    try {
      final result = await _request(
        state,
        'tools/call',
        {'name': toolName, 'arguments': args},
      );
      if (result['isError'] == true) {
        await _sendJson(request, HttpStatus.ok,
            {'ok': false, 'error': _textContent(result)});
        return;
      }
      await _sendJson(request, HttpStatus.ok, {'ok': true, 'payload': result});
    } on BridgeServerException catch (error) {
      await _sendJson(
          request, HttpStatus.ok, {'ok': false, 'error': error.message});
    }
  }

  bool _authorized(HttpRequest request) {
    if (_config.token.isEmpty) return true;
    return request.headers.value('X-Shelly-Bridge-Token') == _config.token;
  }

  /// Merged catalog across every live server, tools named `<id>.<tool>`.
  List<Map<String, dynamic>> catalog() => [
        for (final state in _states.values)
          if (state.alive)
            for (final tool in state.tools)
              {
                'name': '${state.def.id}.${tool['name']}',
                'server': state.def.id,
                'serverName': state.def.name,
                'tool': tool['name'],
                'description': tool['description'] ?? '',
                'inputSchema': tool['inputSchema'],
              },
      ];

  /// `{ok, servers:[{id,name,alive,toolCount}]}` — intentionally flat so it
  /// doubles as a process-level health probe.
  Map<String, dynamic> healthPayload() => {
        'ok': true,
        'servers': [
          for (final state in _states.values)
            {
              'id': state.def.id,
              'name': state.def.name,
              'alive': state.alive,
              'toolCount': state.tools.length,
            },
        ],
      };

  static String _textContent(Map<String, dynamic> result) {
    final content = result['content'];
    final text = [
      if (content is List)
        for (final block in content)
          if (block is Map<String, dynamic> && block['type'] == 'text')
            block['text'] as String? ?? '',
    ].where((part) => part.isNotEmpty).join('\n');
    return text.isEmpty ? 'MCP 工具执行失败' : text;
  }

  Future<void> _drainBody(HttpRequest request) async {
    await utf8.decoder.bind(request).join();
  }

  Future<void> _sendJson(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _ServerState {
  _ServerState(this.def);

  final BridgeStdioServerDef def;
  BridgeProcess? process;
  StreamSubscription<String>? stdoutSub;
  final Map<int, Completer<Map<String, dynamic>>> pending = {};
  int nextId = 1;
  List<Map<String, dynamic>> tools = const [];
  bool alive = false;
  int failures = 0;
  Timer? restartTimer;
  DateTime? startedAt;

  void attach(BridgeProcess process) {
    this.process = process;
    tools = const [];
  }

  void detach() {
    process = null;
  }
}

/// Real-process adapter; stderr is drained so a chatty child can never block
/// on a full pipe.
class _IoProcess implements BridgeProcess {
  _IoProcess(Process process) : _process = process {
    _process.stderr.listen(
      (data) {},
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  final Process _process;

  @override
  Stream<String> get stdoutLines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  void writeLine(String line) {
    _process.stdin.writeln(line);
  }

  @override
  void kill() {
    _process.kill();
  }

  @override
  Future<void> get done => _process.exitCode;
}
