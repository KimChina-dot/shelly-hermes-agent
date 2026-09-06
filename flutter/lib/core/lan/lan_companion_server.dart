import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';

/// Shape of the injectable conversations loader: the same JSON maps
/// `ConversationSummary.toJson` produces in the settings store. The server
/// stays a pure `dart:io` component and never imports the state layer.
typedef LanConversationsLoader = List<Map<String, dynamic>> Function();

/// Shape of the injectable checkpoint loader: mirrors
/// `SettingsStore.loadCheckpoint` — the core [AgentCheckpoint] model, null
/// when the conversation does not exist.
typedef LanCheckpointLoader = AgentCheckpoint? Function(
    String conversationId);

/// Read-only LAN companion server (PHASE 42). Serves the app status, the
/// conversation list and one conversation's checkpoint messages over plain
/// HTTP so a desktop client on the same network can follow along. Every
/// route requires the pairing token (header `X-Shelly-Token` or `?token=`);
/// responses are JSON only and never exceed read-only reads.
///
/// All collaborators are injectable — version, model id, data loaders and
/// the clock — so the server runs in a bare `dart test` VM exactly as it
/// will on Android. Every entry point is failure-proof: `start()` returns
/// null instead of throwing, and handler exceptions turn into 500 JSON
/// responses instead of escaping the server loop.
class LanCompanionServer {
  LanCompanionServer({
    this.port = defaultPort,
    required this.token,
    this.version = '',
    String Function()? modelId,
    this.loadConversations,
    this.loadCheckpoint,
    DateTime Function()? clock,
  })  : _modelId = modelId ?? (() => ''),
        _clock = clock ?? DateTime.now;

  /// Default LAN port; the app always serves the companion on this port.
  static const int defaultPort = 8765;

  /// Port to bind; `0` asks the OS for an ephemeral port (used by tests).
  final int port;

  /// The pairing token every request must present.
  final String token;

  /// App version reported by `/status`.
  final String version;

  final String Function() _modelId;

  /// Injectable data loaders; null falls back to empty/absent payloads.
  final LanConversationsLoader? loadConversations;
  final LanCheckpointLoader? loadCheckpoint;

  /// Injectable clock for the uptime counter; production stamps
  /// [DateTime.now].
  final DateTime Function() _clock;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  DateTime? _startedAt;

  /// Whether the server currently holds a bound socket.
  bool get isRunning => _server != null;

  /// Binds the HTTP server and starts serving. Returns the actually bound
  /// port (differs from [port] when binding port 0), or null when the bind
  /// failed — never throws. Starting an already-running server is a no-op
  /// that returns the current port.
  Future<int?> start() async {
    final existing = _server;
    if (existing != null) return existing.port;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } catch (_) {
      return null;
    }
    _startedAt = _clock();
    _server = server;
    _subscription = server.listen(
      _handle,
      onError: (_, _) {},
      cancelOnError: false,
    );
    return server.port;
  }

  /// Closes the listening socket and any open connections. Idempotent.
  Future<void> stop() async {
    final subscription = _subscription;
    final server = _server;
    _subscription = null;
    _server = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {}
    }
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  /// Whether the request presents the pairing token, via the
  /// `X-Shelly-Token` header or the `token` query parameter.
  bool _authorized(HttpRequest request) {
    final header = request.headers.value('X-Shelly-Token');
    if (header != null && header == token) return true;
    final query = request.uri.queryParameters['token'];
    return query != null && query == token;
  }

  int get _uptimeSec {
    final startedAt = _startedAt;
    if (startedAt == null) return 0;
    final seconds = _clock().difference(startedAt).inSeconds;
    return seconds.isNegative ? 0 : seconds;
  }

  Map<String, dynamic> _statusPayload() => {
        'app': 'shelly-hermes',
        'version': version,
        'uptimeSec': _uptimeSec,
        'conversationCount': _conversationCount(),
        'modelId': _modelId(),
      };

  int _conversationCount() {
    final loader = loadConversations;
    if (loader == null) return 0;
    return loader().length;
  }

  /// Single request handler. Never lets an exception escape into the server
  /// loop: unexpected failures become a 500 JSON response.
  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set('Access-Control-Allow-Origin', '*');
      if (request.method == 'OPTIONS') {
        // Browser-based desktop clients adding the custom token header
        // preflight first; grant it without exposing any data.
        response.statusCode = HttpStatus.noContent;
        response.headers.set('Access-Control-Allow-Methods', 'GET');
        response.headers.set('Access-Control-Allow-Headers', 'X-Shelly-Token');
        await response.close();
        return;
      }
      if (request.method != 'GET') {
        await _writeJson(response, HttpStatus.methodNotAllowed,
            {'error': 'method_not_allowed'});
        return;
      }
      if (!_authorized(request)) {
        await _writeJson(
            response, HttpStatus.unauthorized, {'error': 'unauthorized'});
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length == 1 && segments[0] == 'status') {
        await _writeJson(response, HttpStatus.ok, _statusPayload());
      } else if (segments.length == 1 && segments[0] == 'conversations') {
        await _writeJson(
            response, HttpStatus.ok, _conversationsPayload());
      } else if (segments.length == 2 && segments[0] == 'conversation') {
        final checkpoint = _checkpointPayload(segments[1]);
        if (checkpoint == null) {
          await _writeJson(
              response, HttpStatus.notFound, {'error': 'not_found'});
        } else {
          await _writeJson(response, HttpStatus.ok, checkpoint);
        }
      } else {
        await _writeJson(
            response, HttpStatus.notFound, {'error': 'not_found'});
      }
    } catch (_) {
      // A late failure after a partial response is unrepairable; the write
      // below then fails too and is swallowed.
      try {
        await _writeJson(response, HttpStatus.internalServerError,
            {'error': 'internal_error'});
      } catch (_) {}
    }
  }

  List<Map<String, dynamic>> _conversationsPayload() {
    final loader = loadConversations;
    if (loader == null) return const [];
    return loader();
  }

  Map<String, dynamic>? _checkpointPayload(String conversationId) {
    final loader = loadCheckpoint;
    if (loader == null) return null;
    final checkpoint = loader(conversationId);
    if (checkpoint == null) return null;
    return {...checkpoint.toJson(), 'id': conversationId};
  }

  Future<void> _writeJson(
    HttpResponse response,
    int status,
    Object payload,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.write(jsonEncode(payload));
    await response.close();
  }
}
