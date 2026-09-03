import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/gateway/model_discovery.dart';
import 'package:shelly_hermes/core/gateway/openai_gateway.dart';
import 'package:shelly_hermes/core/gateway/providers.dart';

class _FakeModelsTransport implements ModelsTransport {
  _FakeModelsTransport(this.status, this.body);

  final int status;
  final String body;
  Map<String, String>? lastHeaders;
  Uri? lastUrl;

  @override
  Future<ChatResponse> get(Uri url, Map<String, String> headers,
      {Duration timeout = const Duration(seconds: 30)}) async {
    lastUrl = url;
    lastHeaders = headers;
    return ChatResponse(statusCode: status, body: body);
  }
}


class _FakeChatTransport implements ChatTransport {
  _FakeChatTransport(this.status);

  final int status;
  ChatRequest? lastRequest;

  @override
  Future<ChatResponse> post(ChatRequest request) async {
    lastRequest = request;
    return ChatResponse(
        statusCode: status,
        body: status == 200
            ? '{"choices":[{"message":{"content":"ok"}}]}'
            : '{"error":{"message":"denied"}}');
  }

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async {
    throw UnimplementedError();
  }
}

void main() {
  test('parses the OpenAI /models payload, sorted and deduplicated',
      () async {
    final transport = _FakeModelsTransport(200, '''
{"object":"list","data":[
  {"id":"gpt-4o","object":"model","owned_by":"openai"},
  {"id":"gpt-3.5-turbo","object":"model","owned_by":"openai"},
  {"id":"gpt-4o","object":"model","owned_by":"openai"}
]}
''');
    final discovery = ModelDiscovery(transport: transport);
    final models = await discovery.listModels(
      baseUrl: 'https://api.example.com/v1/',
      apiKey: 'sk-test',
    );
    expect(models.map((m) => m.id).toList(), ['gpt-3.5-turbo', 'gpt-4o']);
    expect(models, hasLength(2));
    expect(models.last.ownedBy, 'openai');
    expect(transport.lastUrl.toString(),
        'https://api.example.com/v1/models');
    expect(transport.lastHeaders?['Authorization'], 'Bearer sk-test');
  });

  test('parses the Ollama native payload shape', () async {
    final transport = _FakeModelsTransport(200, '''
{"models":[
  {"name":"qwen2.5:7b"},
  {"name":"llama3.1:8b","model":"llama3.1:8b"},
  {"digest":"ignored-no-name"}
]}
''');
    final models = await ModelDiscovery(transport: transport)
        .listModels(baseUrl: 'http://localhost:11434/v1');
    expect(models.map((m) => m.id).toList(), ['llama3.1:8b', 'qwen2.5:7b']);
  });

  test('a missing key sends no Authorization header', () async {
    final transport = _FakeModelsTransport(200, '{"data":[]}');
    await ModelDiscovery(transport: transport)
        .listModels(baseUrl: 'http://localhost:1234/v1');
    expect(transport.lastHeaders?.containsKey('Authorization'), isFalse);
  });

  test('error status becomes a GatewayException with the status code',
      () async {
    final discovery = ModelDiscovery(
      transport: _FakeModelsTransport(401, '{"error":"bad key"}'),
    );
    await expectLater(
      discovery.listModels(baseUrl: 'https://api.example.com/v1'),
      throwsA(isA<GatewayException>()
          .having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

  test('malformed and unrecognized payloads become GatewayException',
      () async {
    final malformed = ModelDiscovery(
      transport: _FakeModelsTransport(200, 'not json'),
    );
    await expectLater(
      malformed.listModels(baseUrl: 'https://api.example.com/v1'),
      throwsA(isA<GatewayException>()),
    );
    final unrecognized = ModelDiscovery(
      transport: _FakeModelsTransport(200, '{"unexpected":true}'),
    );
    await expectLater(
      unrecognized.listModels(baseUrl: 'https://api.example.com/v1'),
      throwsA(isA<GatewayException>()),
    );
  });

  test('provider presets cover the common endpoints', () {
    expect(presetById('deepseek')?.defaultBaseUrl,
        'https://api.deepseek.com/v1');
    expect(presetById('qwen')?.defaultBaseUrl,
        contains('compatible-mode'));
    expect(presetById('ollama')?.requiresApiKey, isFalse);
    expect(presetById('custom')?.defaultBaseUrl, isEmpty);
    expect(presetById('nope'), isNull);
    expect(llmProviderPresets, everyElement(isA<LlmProviderPreset>()));
  });

  test('testConnection returns latency for a successful ping', () async {
    final transport = _FakeChatTransport(200);
    final discovery = ModelDiscovery(chatTransport: transport);

    final latency = await discovery.testConnection(
      baseUrl: 'https://api.example.com/v1',
      model: 'gpt-4o-mini',
      apiKey: 'sk-test',
    );

    expect(latency, isNotNull);
    expect(transport.lastRequest!.url, 'https://api.example.com/v1/chat/completions');
    expect(transport.lastRequest!.body, contains('"max_tokens":1'));
    expect(transport.lastRequest!.body, contains('"model":"gpt-4o-mini"'));
    expect(transport.lastRequest!.headers['Authorization'], 'Bearer sk-test');
  });

  test('testConnection surfaces the HTTP status in GatewayException',
      () async {
    final discovery =
        ModelDiscovery(chatTransport: _FakeChatTransport(401));

    await expectLater(
      discovery.testConnection(
        baseUrl: 'https://api.example.com/v1',
        model: 'gpt-4o-mini',
        apiKey: 'bad',
      ),
      throwsA(isA<GatewayException>()
          .having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

}
