import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'openai_gateway.dart';

/// One model advertised by the endpoint's `GET /models`.
class RemoteModel {
  const RemoteModel({required this.id, this.ownedBy = ''});

  final String id;
  final String ownedBy;
}

/// HTTP port used only by model discovery, so the [ChatTransport]
/// interface (POST-only by design) stays untouched and existing fakes
/// keep compiling.
abstract interface class ModelsTransport {
  Future<ChatResponse> get(Uri url, Map<String, String> headers,
      {Duration timeout});
}

class HttpModelsTransport implements ModelsTransport {
  HttpModelsTransport({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<ChatResponse> get(Uri url, Map<String, String> headers,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final response = await _client.get(url, headers: headers).timeout(timeout);
    return ChatResponse(statusCode: response.statusCode, body: response.body);
  }
}

/// Model Discovery (V2.0 PHASE 18): lists the models an OpenAI-compatible
/// endpoint serves (`GET {baseUrl}/models`). Also understands the Ollama
/// native shape (`{"models":[{"name":...}]}`) so local setups work with
/// either their OpenAI-compatible or native endpoint.
class ModelDiscovery {
  ModelDiscovery({ModelsTransport? transport, ChatTransport? chatTransport})
      : _transport = transport ?? HttpModelsTransport(),
        _probeTransport = chatTransport;

  final ModelsTransport _transport;
  final ChatTransport? _probeTransport;

  /// 测试连接 using this discovery's chat transport (test-injectable).
  Future<Duration> testConnection({
    required String baseUrl,
    required String model,
    String apiKey = '',
    Map<String, String> extraHeaders = const {},
    Duration timeout = const Duration(seconds: 20),
  }) =>
      testConnectionWith(
        _probeTransport ?? HttpChatTransport(),
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
        extraHeaders: extraHeaders,
        timeout: timeout,
      );

  Future<List<RemoteModel>> listModels({
    required String baseUrl,
    String apiKey = '',
    Map<String, String> extraHeaders = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final normalized =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final headers = <String, String>{
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      ...extraHeaders,
    };
    final ChatResponse response;
    try {
      response = await _transport
          .get(Uri.parse('$normalized/models'), headers, timeout: timeout);
    } on TimeoutException {
      throw GatewayException('model discovery timed out');
    }
    if (!response.isSuccessful) {
      throw GatewayException(
        'model discovery failed',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    return parseModelsPayload(response.body);
  }
}

/// Round-trip latency of a minimal chat completion (`max_tokens: 1`).
/// Used by the model picker's 测试连接: [GatewayException.statusCode]
/// carries the endpoint's HTTP status so the UI can humanize 401/404/429.
Future<Duration> testConnectionWith(
  ChatTransport transport, {
  required String baseUrl,
  required String model,
  String apiKey = '',
  Map<String, String> extraHeaders = const {},
  Duration timeout = const Duration(seconds: 20),
}) async {
  final normalized =
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  final request = ChatRequest(
    url: '$normalized/chat/completions',
    headers: {
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      ...extraHeaders,
    },
    body: jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': 'ping'}
      ],
      'max_tokens': 1,
      'stream': false,
    }),
    timeout: timeout,
  );
  final watch = Stopwatch()..start();
  ChatResponse response;
  try {
    response = await transport.post(request).timeout(timeout);
  } on TimeoutException {
    throw GatewayException('connection test timed out');
  }
  watch.stop();
  if (!response.isSuccessful) {
    throw GatewayException(
      'connection test failed',
      statusCode: response.statusCode,
      body: response.body,
    );
  }
  return watch.elapsed;
}

/// Parses the `{"data":[{"id":...}]}` (OpenAI) or
/// `{"models":[{"id"|"name":...}]}` (Ollama native) payload; sorted,
/// de-duplicated by id.
List<RemoteModel> parseModelsPayload(String body) {
  late final Map<String, dynamic> payload;
  try {
    payload = jsonDecode(body) as Map<String, dynamic>;
  } on FormatException {
    throw GatewayException('malformed JSON from model discovery', body: body);
  }
  final items = (payload['data'] as List<dynamic>? ?? payload['models'])
      as List<dynamic>?;
  if (items == null) {
    throw GatewayException(
        'unrecognized model discovery payload', body: body);
  }
  final models = <RemoteModel>[];
  for (final item in items) {
    if (item is! Map<String, dynamic>) continue;
    final id = (item['id'] ?? item['name']) as String?;
    if (id == null || id.isEmpty) continue;
    models.add(RemoteModel(
      id: id,
      ownedBy: item['owned_by'] as String? ?? '',
    ));
  }
  final seen = <String>{};
  return [
    ...models.where((m) => seen.add(m.id)),
  ]..sort((a, b) => a.id.compareTo(b.id));
}
