import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/gateway/openai_gateway.dart';
import 'package:shelly_hermes/core/gateway/openai_messages.dart';
import 'package:shelly_hermes/core/gateway/sse.dart';
import 'package:shelly_hermes/core/models.dart';

AgentMessage msg(MessageRole role, String content, {String? toolCallId}) =>
    AgentMessage(role: role, content: content, toolCallId: toolCallId);

void main() {
  group('message encoding', () {
    test('maps all four roles onto the OpenAI schema', () {
      final encoded = encodeMessages([
        msg(MessageRole.system, '你是 Shelly'),
        msg(MessageRole.user, 'hi'),
        const AgentMessage(
          role: MessageRole.assistant,
          content: 'calling tool',
          toolCalls: [ToolCall(id: 't1', name: 'read_file', argumentsJson: '{"path":"a"}')],
        ),
        msg(MessageRole.tool, 'file body', toolCallId: 't1'),
      ]);

      expect(encoded[0], {'role': 'system', 'content': '你是 Shelly'});
      expect(encoded[1], {'role': 'user', 'content': 'hi'});
      expect(encoded[2]['role'], 'assistant');
      expect((encoded[2]['tool_calls'] as List).first['id'], 't1');
      expect(encoded[3], {'role': 'tool', 'tool_call_id': 't1', 'content': 'file body'});
    });
  });

  group('response decoding', () {
    test('decodes content, tool calls and usage (both token vocabularies)', () {
      final payload = decodeMessagePayload({
        'choices': [
          {
            'message': {
              'content': 'done',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {'name': 'list_files', 'arguments': '{}'},
                },
              ],
            },
          },
        ],
        'usage': {'prompt_tokens': 11, 'completion_tokens': 7},
      });

      expect(payload.content, 'done');
      expect(payload.toolCalls.single.id, 'call_1');
      expect(payload.toolCalls.single.name, 'list_files');
      expect(payload.inputTokens, 11);
      expect(payload.outputTokens, 7);

      final alt = decodeMessagePayload({
        'choices': [
          {'message': {'content': ''}},
        ],
        'usage': {'input_tokens': 3, 'output_tokens': 4},
      });
      expect(alt.inputTokens, 3);
      expect(alt.outputTokens, 4);
    });
  });

  group('SSE parser', () {
    test('emits data payloads across chunk boundaries', () async {
      final parser = SseParser();
      final received = <String>[];
      parser.data.listen(received.add);

      parser.addChunk('data: {"a"');
      parser.addChunk(':1}\n\n');
      parser.addChunk(': keep-alive\ndata: [DONE]\n\n');
      await parser.close();

      expect(received, ['{"a":1}', '[DONE]']);
    });
  });

  group('tool call accumulation', () {
    test('assembles streamed fragments by index', () {
      final acc = ToolCallAccumulator();
      acc.addFragments([
        {'index': 0, 'id': 'c1', 'function': {'name': 'apply_patch', 'arguments': '{"pat'}},
      ]);
      acc.addFragments([
        {'index': 0, 'function': {'arguments': 'h":"x}"}'}},
        {'index': 1, 'id': 'c2', 'function': {'name': 'read_file', 'arguments': '{}'}},
      ]);

      final calls = acc.build();
      expect(calls.length, 2);
      expect(calls[0].id, 'c1');
      expect(calls[0].name, 'apply_patch');
      expect(calls[0].argumentsJson, '{"path":"x}"}');
      expect(calls[1].id, 'c2');
    });
  });

  group('OpenAiCompatibleGateway with fake transport', () {
    test('non-streaming complete returns decoded reply', () async {
      final transport = _FakeTransport(responseBody: jsonEncode({
        'choices': [
          {'message': {'content': '你好'}},
        ],
        'usage': {'prompt_tokens': 5, 'completion_tokens': 3},
      }));
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'test-model',
        transport: transport,
      );

      final reply = await gateway.complete([msg(MessageRole.user, 'hi')]);

      expect(reply.content, '你好');
      final request = transport.lastRequest!;
      expect(request.url, 'https://api.example.com/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer sk-test');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'test-model');
      expect(body['stream'], false);
    });

    test('retries on 5xx then succeeds', () async {
      final transport = _FakeTransport.failing(times: 1, body: jsonEncode({
        'choices': [
          {'message': {'content': 'ok'}},
        ],
      }));
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://api.example.com',
        apiKey: 'k',
        model: 'm',
        transport: transport,
        retryDelay: const Duration(milliseconds: 1),
      );

      final reply = await gateway.complete([msg(MessageRole.user, 'hi')]);

      expect(reply.content, 'ok');
      expect(transport.postCalls, 2);
    });

    test('gives up after max retries and surfaces the status', () async {
      final transport = _FakeTransport.failing(times: 99, body: 'down');
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://api.example.com',
        apiKey: 'k',
        model: 'm',
        transport: transport,
        maxRetries: 2,
        retryDelay: const Duration(milliseconds: 1),
      );

      await expectLater(
        gateway.complete([msg(MessageRole.user, 'hi')]),
        throwsA(isA<GatewayException>()),
      );
      expect(transport.postCalls, 3); // initial + 2 retries
    });

    test('streaming assembles content deltas and tool calls', () async {
      final chunks = [
        'data: {"choices":[{"delta":{"content":"He"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":"llo"}}]}',
        '',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c9","function":{"name":"read_file","arguments":"{}"}}]}}]}',
        '',
        'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":9,"completion_tokens":2}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n');
      final transport = _FakeTransport(streamText: chunks);
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://api.example.com',
        apiKey: 'k',
        model: 'm',
        transport: transport,
      );

      final deltas = <String>[];
      final reply = await gateway.completeStreaming(
        [msg(MessageRole.user, 'hi')],
        deltas.add,
      );

      expect(deltas.join(), 'Hello');
      expect(reply.content, 'Hello');
      expect(reply.toolCalls.single.id, 'c9');
      expect(reply.toolCalls.single.name, 'read_file');
      expect(reply.inputTokens, 9);
      expect(reply.outputTokens, 2);
      expect(jsonDecode(transport.lastRequest!.body)['stream'], true);
    });

    test('streaming error status surfaces GatewayException', () async {
      final transport = _FakeTransport.streamError(500, body: 'boom');
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://api.example.com',
        apiKey: 'k',
        model: 'm',
        transport: transport,
      );

      await expectLater(
        gateway.completeStreaming([msg(MessageRole.user, 'hi')], (_) {}),
        throwsA(isA<GatewayException>()),
      );
    });
  });
}

class _FakeTransport implements ChatTransport {
  _FakeTransport({this.responseBody, this.streamText});

  _FakeTransport.failing({required int times, required String body})
      : _failuresRemaining = times,
        _forcedBody = body;

  _FakeTransport.streamError(int status, {required String body})
      : _streamStatus = status,
        _forcedBody = body;

  String? responseBody;
  String? streamText;
  String? _forcedBody;
  int _failuresRemaining = 0;
  int _streamStatus = 200;
  int postCalls = 0;
  ChatRequest? lastRequest;
  @override
  Future<ChatResponse> post(ChatRequest request) async {
    postCalls += 1;
    lastRequest = request;
    if (_failuresRemaining > 0) {
      _failuresRemaining -= 1;
      return ChatResponse(statusCode: 500, body: 'server error');
    }
    return ChatResponse(statusCode: 200, body: responseBody ?? _forcedBody ?? '');
  }

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async {
    lastRequest = request;
    return ChatStreamResponse(
      statusCode: _streamStatus,
      chunks: Stream.value(_streamStatus == 200 ? (streamText ?? '') : (_forcedBody ?? '')),
    );
  }
}
