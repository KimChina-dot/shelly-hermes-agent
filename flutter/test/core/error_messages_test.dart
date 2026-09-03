import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/error_messages.dart';
import 'package:shelly_hermes/core/gateway/openai_gateway.dart';

void main() {
  test('status codes map to actionable Chinese copy', () {
    String at(int status) =>
        humanizeAgentError(GatewayException('x', statusCode: status));

    expect(at(401), contains('密钥'));
    expect(at(403), contains('权限'));
    expect(at(404), contains('/v1'));
    expect(at(429), contains('限流'));
    expect(at(503), contains('暂时不可用'));
  });

  test('400 body sniffing distinguishes model vs context errors', () {
    expect(
      humanizeAgentError(GatewayException('bad', statusCode: 400,
          body: 'This model\'s maximum context length is exceeded')),
      contains('上下文'),
    );
    expect(
      humanizeAgentError(GatewayException('bad', statusCode: 400,
          body: 'The model `gpt-9` does not exist')),
      contains('模型名称'),
    );
  });

  test('transport failures map to network copy', () {
    expect(humanizeAgentError(Exception('SocketException: failed')),
        contains('无法连接'));
    expect(humanizeAgentError(Exception('TimeoutException after 30s')),
        contains('超时'));
    expect(humanizeAgentError(null), '未知错误');
  });
}
